# vim: set ft=make :
# Replaces Bazzite's file of the same name: 70-justfile.sh proves the base's
# copy holds exactly this recipe, so the base's own import brings ours. The
# image ships libvirt enabled, so the recipe reports and hands kvmfr to its
# helper (docs/conventions.md § ujust recipes).

# Report the virtualization state of this host. Options: status | kvmfr
[group("virtualization")]
setup-virtualization ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"

    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust setup-virtualization <option>"
      echo "  status  What the image ships and what this host has"
      echo "  kvmfr   Set up the kvmfr module for Looking Glass (asks for confirmation); undo:"
      echo "          sudo rpm-ostree kargs --delete=kvmfr.static_size_mb=128 (the 128 MiB held"
      echo "          at boot), sudo semodule -r kvmfr, sudo semanage fcontext -d /dev/kvmfr0,"
      echo "          then remove /etc/udev/rules.d/99-kvmfr.rules and /etc/modprobe.d/kvmfr.conf"
      echo "Without an option a menu asks, status first."
      echo "libvirt, virt-manager, quickemu and the KVM options are in the image, with"
      echo "wheel users in the libvirt group from the boot after joining wheel. Nothing to enable."
      exit 0
    fi

    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
      exit 1
    fi

    if [ "$OPTION" == "" ]; then
      OPTION=$(Choose "Show status" "Set up kvmfr (Looking Glass)")
    fi

    case "${OPTION,,}" in
      *status*)
        ok() {
          echo "${green}ok${normal}   $*"
        }
        ko() {
          echo "${red}FAIL${normal} $*"
        }

        if [ "$(systemctl is-enabled virtqemud.socket 2>/dev/null)" == "enabled" ]; then
          active=$(systemctl is-active virtqemud.socket 2>/dev/null || true)
          ok "virtqemud.socket enabled (${active:-unknown})"
        else
          ko "virtqemud.socket is not enabled"
        fi

        if [ -e /dev/kvm ]; then
          ok "/dev/kvm present"
        else
          ko "/dev/kvm missing (virtualization off in firmware, or no KVM support)"
        fi

        # The virsh probe runs only for a group member: for anyone else polkit
        # asks for a password on the terminal and status never returns.
        user_groups=$(id -nG | tr ' ' '\n' || true)

        if grep -qx libvirt <<< "$user_groups"; then
          ok "$USER is in the libvirt group"

          if virsh -c qemu:///system uri >/dev/null 2>&1; then
            ok "virsh reaches qemu:///system"
          else
            ko "virsh cannot reach qemu:///system"
          fi
        else
          ko "$USER is not in the libvirt group yet (granted at boot to wheel members only:" \
            "a wheel user gets it at the next boot, then logs out and in; another account needs" \
            "'sudo usermod -aG libvirt $USER')"
          echo "     virsh probe skipped until then"
        fi

        ignore_msrs=$(cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null || true)
        echo "     kvm ignore_msrs=${ignore_msrs:-kvm not loaded}"

        if [ -e /dev/kvmfr0 ]; then
          echo "     kvmfr: /dev/kvmfr0 present (Looking Glass ready)"
        elif [ -e /etc/udev/rules.d/99-kvmfr.rules ]; then
          echo "     kvmfr: set up, /dev/kvmfr0 appears at the next boot"
        else
          echo "     kvmfr: not set up (ujust setup-virtualization kvmfr)"
        fi

        quickemu_version=$(quickemu --version 2>/dev/null | head -n1 || true)
        echo "     quickemu ${quickemu_version:-version unknown}"
        ;;
      *kvmfr*)
        sudo /usr/libexec/bazzite-dx-kvmfr-setup
        ;;
      "")
        exit 0
        ;;
      *)
        echo "Unknown option: $OPTION (ujust setup-virtualization help)"
        exit 1
        ;;
    esac
