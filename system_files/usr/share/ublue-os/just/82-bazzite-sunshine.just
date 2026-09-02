# vim: set ft=make :

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
      echo "  status           Whether Sunshine runs for this user (default)"
      echo "  enable           Start Sunshine now and at every login of this user"
      echo "  disable          Stop it and remove it from the login of this user"
      echo "  portal           Open the management portal (https://localhost:47990)"
      echo "  virtual-monitor  Add an app that creates a KWin virtual display per stream"
      exit 0
    fi
    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
      exit 1
    fi
    if [ "$OPTION" == "" ]; then
      OPTION=$(Choose "Show status" "Enable Sunshine" "Disable Sunshine" "Open portal" "Set up virtual monitor")
    fi
    case "${OPTION,,}" in
      *status*)
        echo "Sunshine $(sunshine --version 2>/dev/null | head -n1 | sed 's/^Sunshine //')"
        echo "$UNIT: $(systemctl --user is-enabled "$UNIT" 2>/dev/null || echo disabled) / $(systemctl --user is-active "$UNIT" 2>/dev/null || echo inactive)"
        echo "capabilities: $(getcap /usr/bin/sunshine | sed 's|^/usr/bin/sunshine ||')"
        if [ -f "$APPS" ] && jq -e '.apps[]? | select(.name == "Virtual Monitor")' "$APPS" >/dev/null 2>&1; then
          echo "virtual monitor: configured in $APPS"
        else
          echo "virtual monitor: not configured (ujust setup-sunshine virtual-monitor)"
        fi
        ;;
      *enable*)
        systemctl --user enable --now "$UNIT"
        echo "Sunshine enabled for $USER: pair Moonlight through ${bold}https://localhost:47990${normal}"
        ;;
      *disable*)
        systemctl --user disable --now "$UNIT"
        echo "Sunshine disabled for $USER"
        ;;
      *portal*)
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
        if [ "$XDG_CURRENT_DESKTOP" != "KDE" ]; then
          echo "Virtual monitors need KDE's KWin compositor (this session: ${XDG_CURRENT_DESKTOP:-unknown})."
          echo "See ${bold}https://docs.bazzite.gg/Advanced/custom_resolution/${normal}"
          exit 1
        fi
        if [ ! -f "$APPS" ]; then
          mkdir -p "$(dirname "$APPS")"
          cp /usr/share/sunshine/apps.json "$APPS"
          echo "Seeded $APPS from the package's default"
        fi
        TMP_FILE=$(mktemp)
        jq --argjson VMON_APP "$VMON_APP" '
          if .apps then
            if any(.apps[]; .name == $VMON_APP.name) then
              .apps |= map(if .name == $VMON_APP.name then $VMON_APP else . end)
            else
              .apps += [$VMON_APP]
            end
          else
            .apps = [$VMON_APP]
          end
        ' "$APPS" > "$TMP_FILE"
        mv "$TMP_FILE" "$APPS"
        echo "Added/updated 'Virtual Monitor' in $APPS"
        printf '[Service]\nExecStopPost=/usr/libexec/sunshine-stop-vmon\n' | systemctl --user edit --stdin "$UNIT"
        systemctl --user daemon-reload
        echo "Set the Capture Method to ${bold}KWin Screencast${normal} in the portal and ${bold}restart Sunshine${normal}"
        echo "(ujust setup-sunshine disable, then enable) for the change to take effect."
        ;;
      *)
        echo "Unknown option: $OPTION (try 'ujust setup-sunshine help')"
        exit 1
        ;;
    esac
