# vim: set ft=make :
# Replaces Bazzite's file of the same name, holding the one recipe the base's
# held, so the base's own import brings ours.

# Manage the Sunshine streaming host for this user. Options: status | enable | disable | portal | virtual-monitor
[group("gaming")]
setup-sunshine ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"
    UNIT=app-dev.lizardbyte.app.Sunshine.service
    APPS="$HOME/.config/sunshine/apps.json"

    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust setup-sunshine <option>"
      echo "  status           Whether Sunshine runs for this user"
      echo "  enable           Start Sunshine now and at every login of this user (one account"
      echo "                   at a time per host: another's cannot bind the ports while one runs)"
      echo "  disable          Stop it and remove it from the login of this user"
      echo "  portal           Open the management portal (https://localhost:47990)"
      echo "  virtual-monitor  Add an app that creates a KWin virtual display per stream; after"
      echo "                   every stop of Sunshine it turns every output on and empties"
      echo "                   output_name; to undo it: systemctl --user revert"
      echo "                   $UNIT"
      echo "                   Each stream also opens VNC on port 5905 to the LAN, with the"
      echo "                   base's fixed password, until the stream ends (until Sunshine"
      echo "                   stops if another account holds /tmp/sunshine-vmon.pid)."
      echo "Without an option a menu asks, status first."
      exit 0
    fi

    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
      exit 1
    fi

    if [ "$OPTION" == "" ]; then
      OPTION=$(Choose "Show status" "Enable Sunshine" "Disable Sunshine" "Open portal" \
        "Set up virtual monitor")
    fi

    case "${OPTION,,}" in
      *status*)
        version=$(rpm -q --qf '%{VERSION}' Sunshine 2>/dev/null || true)
        echo "Sunshine ${version:-version unknown}"

        enabled=$(systemctl --user is-enabled "$UNIT" 2>/dev/null || true)
        active=$(systemctl --user is-active "$UNIT" 2>/dev/null || true)
        echo "$UNIT: ${enabled:-unknown} / ${active:-unknown}"
        # getcap prints nothing, status 0, for a binary without capabilities.
        caps=$(getcap /usr/bin/sunshine 2>/dev/null | sed 's|^/usr/bin/sunshine ||' || true)
        echo "capabilities: ${caps:-none}"

        if [ -f "$APPS" ] \
          && jq -e '.apps[]? | select(.name == "Virtual Monitor")' "$APPS" >/dev/null 2>&1; then
          echo "virtual monitor: configured in $APPS"
        else
          echo "virtual monitor: not configured (ujust setup-sunshine virtual-monitor)"
        fi

        # The drop-in outlives the app: nothing removes it, and a Sunshine
        # stopped without it restores the outputs itself. Reported on its own
        # line so a host whose app was deleted from the portal is not read as
        # a host without the hook.
        DROP_IN="$HOME/.config/systemd/user/$UNIT.d/override.conf"

        if [ -f "$DROP_IN" ]; then
          echo "virtual monitor hook: $DROP_IN (systemctl --user revert $UNIT removes it)"
        else
          echo "virtual monitor hook: none"
        fi
        ;;
      *enable*)
        # A copy Bazzite's Sunshine Flatpak left in the home comes first in the
        # user unit path (systemd-analyze --user unit-paths) and runs the Flatpak.
        FRAGMENT=$(systemctl --user show -p FragmentPath --value "$UNIT" 2>/dev/null || true)

        if [[ $FRAGMENT == "$HOME"/* ]]; then
          echo "ERROR: $FRAGMENT shadows the RPM's unit: run 'flatpak run" \
            "--command=remove-additional-install.sh dev.lizardbyte.app.Sunshine', or remove" \
            "the file and run 'systemctl --user daemon-reload'" >&2
          exit 1
        fi

        # The portal admits the LAN by default (LizardByte/Sunshine,
        # docs/configuration.md); a value already in the file is the user's.
        CONF="$HOME/.config/sunshine/sunshine.conf"
        WROTE=0

        if ! grep -qE '^[[:space:]]*origin_web_ui_allowed[[:space:]]*=' "$CONF" 2> /dev/null; then
          if ! mkdir -p "$(dirname "$CONF")" 2> /dev/null \
            || ! echo "origin_web_ui_allowed = pc" 2> /dev/null >> "$CONF"; then
            echo "ERROR: cannot write $CONF" >&2
            exit 1
          fi

          echo "Portal limited to this PC: origin_web_ui_allowed = pc in $CONF"
          WROTE=1
        fi

        # Until a username exists /api/password takes one from any origin
        # (docs/divergences.md § Sunshine), so it is set before the start.
        STATE="$HOME/.config/sunshine/sunshine_state.json"

        if ! jq -e '(.username // "") != ""' "$STATE" > /dev/null 2>&1; then
          echo "No portal credentials yet: choose them now."
          read -rp "Username: " NEW_USER
          IFS= read -rsp "Password: " NEW_PASSWORD
          echo
          IFS= read -rsp "Password again: " PASSWORD_AGAIN
          echo

          if [ -z "$NEW_USER" ] || [ -z "$NEW_PASSWORD" ] \
            || [ "$NEW_PASSWORD" != "$PASSWORD_AGAIN" ]; then
            echo "ERROR: empty username or password, or the two passwords differ" >&2
            exit 1
          fi

          if ! CREDS_OUT=$(sunshine --creds "$NEW_USER" "$NEW_PASSWORD" 2>&1); then
            echo "ERROR: sunshine --creds failed: $(tail -n1 <<< "$CREDS_OUT")" >&2
            exit 1
          fi

          echo "Credentials saved ($STATE)"
          WROTE=1
        fi

        # A Sunshine already running rereads the files only on a restart; with
        # nothing written it is left running, its stream with it.
        if [ "$WROTE" -eq 1 ]; then
          if ! systemctl --user enable "$UNIT" || ! systemctl --user restart "$UNIT"; then
            exit 1
          fi
        elif ! systemctl --user enable --now "$UNIT"; then
          exit 1
        fi

        echo "Sunshine enabled for $USER: pair Moonlight through" \
          "${bold}https://localhost:47990${normal}"
        echo "The stream is reachable from the LAN, the portal from where" \
          "origin_web_ui_allowed in $CONF allows."
        ;;
      *disable*)
        if ! systemctl --user disable --now "$UNIT"; then
          exit 1
        fi

        echo "Sunshine disabled for $USER"
        ;;
      *portal*)
        echo "Sunshine web UI: https://localhost:47990"
        xdg-open https://localhost:47990
        ;;
      *virtual*)
        # The app Bazzite's recipe adds, for the RPM: the prep commands call
        # the base's helpers directly, without flatpak-spawn.
        VMON_APP='{
          "auto-detach": true,
          "cmd": "",
          "elevated": false,
          "exclude-global-prep-cmd": false,
          "exit-timeout": 5,
          "image-path": "",
          "name": "Virtual Monitor",
          "output": "",
          "prep-cmd": [
            {
              "do": "sh -c \"/usr/libexec/sunshine-start-vmon\"",
              "undo": "sh -c \"/usr/libexec/sunshine-stop-vmon\""
            }
          ],
          "wait-all": true
        }'

        base=$(jq -r '."base-image-name"' /usr/share/ublue-os/image-info.json)

        if [ "$base" != "kinoite" ]; then
          echo "Virtual monitors need KDE's KWin compositor (this image's base: $base)."
          echo "See ${bold}https://docs.bazzite.gg/Advanced/custom_resolution/${normal}"
          exit 1
        fi

        if [ ! -f "$APPS" ]; then
          if ! mkdir -p "$(dirname "$APPS")" 2> /dev/null \
            || ! cp /usr/share/sunshine/apps.json "$APPS" 2> /dev/null; then
            echo "ERROR: cannot seed $APPS from /usr/share/sunshine/apps.json" >&2
            exit 1
          fi

          echo "Seeded $APPS from the package's default"
        fi

        # The app replaces an existing one of the same name, else it is appended;
        # a file jq cannot read is left as it is. The temporary file is beside
        # apps.json so the final mv is a rename: from /tmp it is a copy, and a
        # full home cuts it short with the user's list gone.
        if ! TMP_FILE=$(mktemp "$APPS.XXXXXX"); then
          exit 1
        fi

        JQ_ERR=$(mktemp)

        if ! jq --argjson VMON_APP "$VMON_APP" '
          if .apps then
            if any(.apps[]; .name == $VMON_APP.name) then
              .apps |= map(if .name == $VMON_APP.name then $VMON_APP else . end)
            else
              .apps += [$VMON_APP]
            end
          else
            .apps = [$VMON_APP]
          end
        ' "$APPS" > "$TMP_FILE" 2> "$JQ_ERR"; then
          REASON=$(paste -sd ' ' "$JQ_ERR")
          rm -f "$TMP_FILE" "$JQ_ERR"
          echo "ERROR: $APPS not rewritten (${REASON:-no output from jq}):" \
            "the file is left as it is" >&2
          exit 1
        fi

        rm -f "$JQ_ERR"

        if ! mv "$TMP_FILE" "$APPS"; then
          rm -f "$TMP_FILE"
          exit 1
        fi

        echo "Added/updated 'Virtual Monitor' in $APPS"

        # The virtual display goes when the service stops, whatever stopped it.
        # `systemctl edit` reloads the manager itself (man 1 systemctl, edit).
        if ! printf '[Service]\nExecStopPost=/usr/libexec/sunshine-stop-vmon\n' \
          | systemctl --user edit --stdin "$UNIT"; then
          exit 1
        fi

        echo "Set the Capture Method to ${bold}KWin Screencast${normal} in the portal and" \
          "${bold}restart Sunshine${normal}"
        echo "(systemctl --user try-restart $UNIT) for the change to take effect."
        ;;
      "")
        exit 0
        ;;
      *)
        echo "Unknown option: $OPTION (ujust setup-sunshine help)"
        exit 1
        ;;
    esac
