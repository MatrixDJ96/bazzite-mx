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
