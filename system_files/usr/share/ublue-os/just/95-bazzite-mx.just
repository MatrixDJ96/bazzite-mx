# vim: set ft=make :
# The image's own recipes, imported last into the master justfile by
# 70-justfile.sh, which refuses a name defined twice. Each recipe is a thin
# front: the help text, the not-as-root check, sudo where root is needed, the
# call of its helper under /usr/libexec (docs/conventions.md § ujust recipes).
# A recipe that prints more after the call prints it only when the call
# succeeded, so a failure reaches just as the recipe's own status.

# Add the taskbar panel to every screen that has none.
[group("desktop")]
setup-panels ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"
    SCRIPT=/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/bazzite-mx-panels.js

    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust setup-panels"
      echo "Every screen without a panel gets a bottom panel like the primary one:"
      echo "no system tray, tasks filtered per screen. A screen that has one is left alone."
      echo "Plasma runs the same script at a first login; this is for a login that had"
      echo "one screen, or for a screen added later."
      exit 0
    fi

    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
      exit 1
    fi

    if [ "$OPTION" != "" ]; then
      echo "Unknown option: $OPTION (ujust setup-panels help)"
      exit 1
    fi

    if ! gdbus introspect --session --dest org.kde.plasmashell --object-path /PlasmaShell \
      >/dev/null 2>&1; then
      echo "plasmashell is not reachable on this session bus: run this inside a Plasma session"
      exit 1
    fi

    # evaluateScript returns what the script print()s, wrapped in a tuple.
    if ! REPORT=$(gdbus call --session --dest org.kde.plasmashell --object-path /PlasmaShell \
      --method org.kde.PlasmaShell.evaluateScript "$(cat "$SCRIPT")"); then
      exit 1
    fi

    REPORT=$(sed -e "s/^('//" -e "s/',)$//" <<< "$REPORT")
    echo "$REPORT"

# Set up the MSI laptop support: the EC modules and MControlCenter. Options: status | enable | disable
[group("hardware")]
setup-msi ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"
    HELPER=/usr/libexec/bazzite-mx-msi-setup

    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust setup-msi <option>"
      echo "  status   Modules, /dev/ec, EC firmware, MControlCenter"
      echo "  enable   Load msi-ec and acpi_ec now and at boot, install MControlCenter"
      echo "  disable  Unload the modules, remove the boot entry and MControlCenter"
      echo "Without an option a menu asks, status first."
      echo "Only an MSI system can enable it, and the modules are unsigned, so Secure Boot"
      echo "has to be off."
      exit 0
    fi

    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
      exit 1
    fi

    if [ "$OPTION" == "" ]; then
      OPTION=$(Choose "Show status" "Enable MSI support" "Disable MSI support")
    fi

    case "${OPTION,,}" in
      *status*)
        "$HELPER" status
        ;;
      *enable*)
        if ! sudo "$HELPER" enable; then
          exit 1
        fi

        echo "${green}Done.${normal} MControlCenter is in the application menu;" \
          "${bold}ujust setup-msi status${normal} shows the helper state."
        ;;
      *disable*)
        sudo "$HELPER" disable
        ;;
      "")
        exit 0
        ;;
      *)
        echo "Unknown option: $OPTION (ujust setup-msi help)"
        exit 1
        ;;
    esac

# Use the NTFSPLUS driver for this host's NTFS volumes. Options: status | enable | disable
[group("hardware")]
setup-ntfsplus ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"
    HELPER=/usr/libexec/bazzite-mx-ntfsplus-setup

    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust setup-ntfsplus <option>"
      echo "  status   Module, opt-in, driver, fstab rows by type, mounted volumes"
      echo "  enable   Prove the driver on a loop image, switch fstab rows ntfs3 -> ntfs, remount"
      echo "  disable  Switch every ntfs row to ntfs3, remount, drop the opt-in and the fstab"
      echo "           backup, unload the driver"
      echo "Without an option a menu asks, status first."
      echo "The image ships the driver as the type ntfs, blacklisted until a host opts in;"
      echo "ntfs3 stays the default and a busy volume keeps its mount until the next boot."
      echo "Once a host opts in, volumes the file manager mounts (udisks) use the driver too."
      echo "enable adds errors=remount-ro to every ntfs row without an errors= option, and"
      echo "udisks mounts take it from the image: a dirty volume, or one Windows hibernated"
      echo "on, mounts read-only. Fast startup can leave a volume with neither sign, which"
      echo "mounts read-write: turn fast startup off in Windows."
      echo "The module is unsigned, so Secure Boot has to be off."
      exit 0
    fi

    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
      exit 1
    fi

    if [ "$OPTION" == "" ]; then
      OPTION=$(Choose "Show status" "Enable NTFSPLUS" "Disable NTFSPLUS")
    fi

    case "${OPTION,,}" in
      *status*)
        "$HELPER" status
        ;;
      *enable*)
        if ! sudo "$HELPER" enable; then
          exit 1
        fi

        echo "${green}Done.${normal} ${bold}ujust setup-ntfsplus status${normal} shows the rows" \
          "and the driver behind each mount."
        ;;
      *disable*)
        sudo "$HELPER" disable
        ;;
      "")
        exit 0
        ;;
      *)
        echo "Unknown option: $OPTION (ujust setup-ntfsplus help)"
        exit 1
        ;;
    esac

# Check this host against what the image expects, one line per check.
[group("system")]
verify-host ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"
    HELPER=/usr/libexec/bazzite-mx-verify-host

    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust verify-host"
      echo "Prints one OK/FAIL/SKIP/INFO line per check, exit 1 on any FAIL: bootc status,"
      echo "signed origin on :stable, nothing layered, signing policy, MSI modules and residue,"
      echo "GPU and flavour, NTFS driver, ntfsplus residue, Firefox Flatpak, image .repo files."
      echo "Runs the checks as root (bootc status needs it). Fixes: ujust migrate."
      exit 0
    fi

    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
      exit 1
    fi

    if [ "$OPTION" != "" ]; then
      echo "Unknown option: $OPTION (ujust verify-host help)"
      exit 1
    fi

    sudo "$HELPER"

# Migrate this host to the signed origin of this image. Options: plan | apply, then a tag.
[group("system")]
migrate ACTION="plan" TAG="stable":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"
    TAG="{{ TAG }}"
    HELPER=/usr/libexec/bazzite-mx-migrate

    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust migrate [plan|apply] [TAG]"
      echo "  plan   Read-only: what apply would do on this host (default)"
      echo "  apply  Do it, each step asking first except step 2 (backups, deployment pin,"
      echo "         update timer stopped); the reboot stays yours"
      echo "  TAG    Tag of the signed origin, default stable; a dated tag pins the host"
      echo "         to that release."
      echo "plan prints the steps and refuses a host it cannot migrate, saying what to do first."
      exit 0
    fi

    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
      exit 1
    fi

    case "$OPTION" in
      plan|apply)
        sudo "$HELPER" "$OPTION" "$TAG"
        ;;
      *)
        echo "Unknown option: $OPTION (ujust migrate help)"
        exit 1
        ;;
    esac

# Install this user's development runtimes with mise. Options: status | install
[group("development")]
setup-dev ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"
    SKEL=/etc/skel/.config/mise/config.toml
    CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.toml"

    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust setup-dev <option>"
      echo "  status   What mise has configured and installed for you"
      echo "  install  Seed $CONFIG from $SKEL when you have none, then 'mise install'"
      echo "Without an option a menu asks, status first."
      echo "The runtimes go under ~/.local/share/mise/installs, per user, except dotnet: mise puts"
      echo "that SDK in ~/.dotnet, next to one already there. A project's own mise.toml overrides"
      echo "the global config. Not for root."
      exit 0
    fi

    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
      exit 1
    fi

    if [ "$OPTION" == "" ]; then
      OPTION=$(Choose "Show status" "Install the default runtimes")
    fi

    case "${OPTION,,}" in
      *status*)
        if [ -f "$CONFIG" ]; then
          echo "config: $CONFIG"
        else
          echo "config: none yet (ujust setup-dev install seeds it from $SKEL)"
        fi

        mise ls
        ;;
      *install*)
        # Written beside and renamed: a copy cut short by a full home would
        # otherwise leave an empty config the next run takes as seeded.
        if [ ! -f "$CONFIG" ]; then
          if ! mkdir -p "$(dirname "$CONFIG")" 2> /dev/null \
            || ! cp "$SKEL" "$CONFIG.new" 2> /dev/null \
            || ! mv -f "$CONFIG.new" "$CONFIG" 2> /dev/null; then
            rm -f "$CONFIG.new"
            echo "ERROR: cannot seed $CONFIG from $SKEL" >&2
            exit 1
          fi

          echo "seeded $CONFIG from $SKEL"
        fi

        if ! mise install; then
          exit 1
        fi

        mise ls
        echo "${green}Done.${normal} Open a new bash: mise activates the runtimes on PATH."
        echo "In fish, add 'if type -q mise; mise activate fish | source; end' to" \
          "~/.config/fish/config.fish."
        ;;
      "")
        exit 0
        ;;
      *)
        echo "Unknown option: $OPTION (ujust setup-dev help)"
        exit 1
        ;;
    esac

# Install JetBrains Toolbox for this user. Options: install | status | latest
[group("apps")]
install-jetbrains-toolbox ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"
    HELPER=/usr/libexec/bazzite-mx-jetbrains-toolbox

    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust install-jetbrains-toolbox <option>"
      echo "  install  Download the latest build, verify its sha256, unpack it under"
      echo "           ~/.local/share/JetBrains/ToolboxApp and start it (default)"
      echo "  status   What is installed here"
      echo "  latest   Build and URLs the feed publishes"
      echo "The tarball is the one JetBrains documents, not a Homebrew cask. Not for root."
      exit 0
    fi

    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
      exit 1
    fi

    case "${OPTION:-install}" in
      install|status|latest)
        "$HELPER" "${OPTION:-install}"
        ;;
      *)
        echo "Unknown option: $OPTION (ujust install-jetbrains-toolbox help)"
        exit 1
        ;;
    esac
