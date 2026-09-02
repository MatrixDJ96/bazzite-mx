# vim: set ft=make :

# Report the virtualization state of this host. Options: status | kvmfr
[group("virtualization")]
setup-virtualization ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION="{{ ACTION }}"
    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust setup-virtualization <option>"
      echo "  status  What the image ships and what this host has (default)"
      echo "  kvmfr   Set up the kvmfr module for Looking Glass (asks for confirmation)"
      echo "libvirt, virt-manager, quickemu and the KVM options are in the image, with"
      echo "wheel users in the libvirt group after the first boot. Nothing to enable."
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
        ok() { echo "${green}ok${n}   $*"; }
        ko() { echo "${red}FAIL${n} $*"; }
        [ "$(systemctl is-enabled virtqemud.socket 2>/dev/null)" == "enabled" ] \
          && ok "virtqemud.socket enabled ($(systemctl is-active virtqemud.socket))" \
          || ko "virtqemud.socket is not enabled"
        [ "$(systemctl is-enabled libvirtd.service 2>/dev/null)" == "enabled" ] \
          && ko "monolithic libvirtd.service is enabled: run 'sudo systemctl disable --now libvirtd.service' (modular daemons are the image's form)" \
          || ok "monolithic libvirtd.service not enabled"
        [ -e /dev/kvm ] && ok "/dev/kvm present" || ko "/dev/kvm missing (virtualization off in firmware, or no KVM support)"
        id -nG | tr ' ' '\n' | grep -qx libvirt \
          && ok "$USER is in the libvirt group" \
          || ko "$USER is not in the libvirt group yet (granted at boot to wheel members; log out and in after the first boot)"
        if virsh -c qemu:///system uri >/dev/null 2>&1; then
          ok "virsh reaches qemu:///system"
        else
          ko "virsh cannot reach qemu:///system"
        fi
        echo "     kvm ignore_msrs=$(cat /sys/module/kvm/parameters/ignore_msrs 2>/dev/null || echo 'kvm not loaded')"
        if [ -e /dev/kvmfr0 ]; then
          echo "     kvmfr: /dev/kvmfr0 present (Looking Glass ready)"
        else
          echo "     kvmfr: not set up (ujust setup-virtualization kvmfr)"
        fi
        echo "     quickemu $(quickemu --version 2>/dev/null | head -n1)"
        ;;
      *kvmfr*)
        sudo /usr/libexec/bazzite-dx-kvmfr-setup
        ;;
      *)
        echo "Unknown option: $OPTION (try 'ujust setup-virtualization help')"
        exit 1
        ;;
    esac
