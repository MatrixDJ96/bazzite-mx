# vim: set ft=make :

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
    if ! gdbus introspect --session --dest org.kde.plasmashell --object-path /PlasmaShell >/dev/null 2>&1; then
      echo "plasmashell is not reachable on this session bus: run this inside a Plasma session"
      exit 1
    fi
    # evaluateScript returns what the script print()s, wrapped in a tuple.
    gdbus call --session --dest org.kde.plasmashell --object-path /PlasmaShell \
      --method org.kde.PlasmaShell.evaluateScript "$(cat "$SCRIPT")" \
      | sed -e "s/^('//" -e "s/',)$//"

# Set up the MSI laptop support: the EC modules and MControlCenter. Options: status | enable | disable
[group("hardware")]
setup-msi ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"
    HELPER=/usr/libexec/bazzite-mx-msi-setup
    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust setup-msi <option>"
      echo "  status   Modules, /dev/ec, EC firmware, MControlCenter (default)"
      echo "  enable   Load msi-ec and acpi_ec now and at boot, install MControlCenter"
      echo "  disable  Unload the modules, remove the boot entry and MControlCenter"
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
        sudo "$HELPER" enable
        echo "${green}Done.${normal} MControlCenter is in the application menu; ${bold}ujust setup-msi status${normal} shows the helper state."
        ;;
      *disable*)
        sudo "$HELPER" disable
        ;;
      *)
        echo "Unknown option: $OPTION (ujust setup-msi help)"
        exit 1
        ;;
    esac

# Check this host against what the image expects: bootc compatible, signed origin on :stable, nothing layered, policy, hardware, NTFS
[group("system")]
verify-host ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"
    HELPER=/usr/libexec/bazzite-mx-verify-host
    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust verify-host"
      echo "Prints one OK/FAIL/SKIP line per check and exits 1 on any FAIL:"
      echo "  bootc status compatible, origin ostree-image-signed:docker://ghcr.io/matrixdj96/<image>:stable,"
      echo "  no layered packages and no local initramfs, signing policy in force, MSI modules on an MSI"
      echo "  host, NVIDIA GPU and flavour agreeing, NTFS volumes on ntfs3, no ntfsplus residue."
      echo "Runs the checks as root (bootc status needs it). Fixes: ujust migrate."
      exit 0
    fi
    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
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
      echo "  apply  Do it, asking before every change; the reboot stays yours"
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
      echo "  status   What mise has configured and installed for you (default)"
      echo "  install  Seed $CONFIG from $SKEL when you have none, then 'mise install'"
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
        if [ ! -f "$CONFIG" ]; then
          mkdir -p "$(dirname "$CONFIG")"
          cp "$SKEL" "$CONFIG"
          echo "seeded $CONFIG from $SKEL"
        fi
        mise install
        mise ls
        echo "${green}Done.${normal} Open a new shell: mise activates the runtimes on PATH."
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
