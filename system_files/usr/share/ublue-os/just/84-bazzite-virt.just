# vim: set ft=make :
#
# 84-bazzite-virt.just — bazzite-mx OVERRIDE of Bazzite's upstream
# virtualization recipe.
#
# Why we override:
#   Upstream's `setup-virtualization virt-on` is gated on
#       if ! rpm -q virt-manager | grep -P "^virt-manager-"; then ...
#   so on bazzite-mx (where virt-manager is RPM-installed at build
#   time, see build_files/mx/20-virtualization.sh) the entire branch
#   is skipped and the user gets nothing — no kargs, no SELinux fix,
#   no libvirt hook setup, and no ACL on $HOME for qemu ISO access.
#
# Our diff vs. upstream Bazzite (system_files/desktop/shared/usr/share
# /ublue-os/just/84-bazzite-virt.just):
#   1. virt-on path: dropped the `! rpm -q virt-manager` gate AND the
#      `flatpak install flathub org.virt_manager.virt-manager` line.
#      Build-time RPM is the source of truth; flatpak is masked
#      separately (build_files/mx/21-virt-manager-flatpak-exclude.sh
#      adds it to /usr/share/ublue-os/flatpak-blocklist).
#   2. virt-on path: dropped the `rpm-ostree kargs --append-if-missing
#      kvm.ignore_msrs=1 / kvm.report_ignored_msrs=0` lines. Those
#      kargs ship pre-set via /usr/lib/bootc/kargs.d/01-bazzite-mx-virt
#      .toml so they exist on first boot, no ujust needed.
#   3. virt-on path: dropped the `bazzite-libvirtd-setup.service`
#      enable line. We enable libvirtd.service unconditionally at
#      build time (same file: 20-virtualization.sh).
#   4. virt-off path: dropped the `flatpak uninstall org.virt_manager
#      .virt-manager` line. RPM removal would leave the host without
#      a GUI manager AND we don't ship the flatpak.
#   5. VFIO / kvmfr / usbhp / group blocks: kept VERBATIM. Those
#      handle hardware passthrough scenarios and are orthogonal.

# Setup and configure virtualization and vfio
setup-virtualization ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    if [[ $(id -u) -eq 0 ]]; then
      echo "Please do not run this command as root"
      exit 1
    fi
    # Check if we are running on a Steam Deck
    if /usr/libexec/hwsupport/valve-hardware; then
      echo "${red}${b}WARNING${n}: Virtualization is not properly supported on Steam Deck by Valve"
      echo "Use at your own risk and performance may not be ideal."
    fi
    if [ "$(systemctl is-enabled libvirtd.service)" == "disabled" ]; then
      echo "${b}libvirtd${n} service is ${red}disabled${n}!"
      echo "${green}enabling${n} and starting libvirtd"
      echo "If virt-manager says libvirtd.sock is not available after a big update, re-run this command."
      sudo systemctl enable --now libvirtd 2> /dev/null
      echo "Press ESC if you want to exit and do not need to do anything"
    fi
    OPTION={{ ACTION }}
    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust setup-virtualization <option>"
      echo "  <option>: Specify the quick option to skip the prompt"
      echo "  Use 'virt-on' to apply per-user virt setup (ACL + libvirt hooks)"
      echo "  Use 'group' to select Add $USER to libvirt group"
      echo "  Use 'vfio-on' to select Enable VFIO drivers"
      echo "  Use 'vfio-off' to select Disable VFIO drivers"
      echo "  Use 'kvmfr' to select Autocreate Looking-Glass shm"
      echo "  Use 'usbhp-on' to select Enable SPICE USB hot plugging"
      echo "  Use 'usbhp-off' to select Disable SPICE USB hot plugging"
      echo "  NOTE: kargs (kvm.ignore_msrs / kvm.report_ignored_msrs) and"
      echo "        libvirtd.service are pre-applied at build time on"
      echo "        bazzite-mx — no virt-off path; uninstall the image"
      echo "        if you don't want virt support."
      exit 0
    elif [ "$OPTION" == "" ]; then
      echo "${bold}Virtualization Setup${normal}"
      echo "NOTE: virt-manager (RPM), kargs and libvirtd are pre-applied at build time."
      echo "      This recipe applies the per-user / per-host bits that"
      echo "      cannot be baked in (ACL, libvirt hooks, group, VFIO, ...)."
      OPTION=$(Choose \
        "Apply per-user virt setup" \
        "Add $USER to libvirt group" \
        "Enable VFIO drivers" \
        "Disable VFIO drivers" \
        "Enable kvmfr module" \
        "Enable USB hot plugging" \
        "Disable USB hot plugging" \
      )
    fi
    if [[ "${OPTION,,}" =~ (^apply[[:space:]]per-user|virt-on) ]]; then
        echo "Making sure swtpm-localca dir is writable by tss"
        # `swtpm-tools` ships /var/lib/swtpm-localca with mode 0750
        # tss:root by default; defensive re-apply in case a previous
        # tweak changed it.
        if [ ! -d "/var/lib/swtpm-localca" ]; then
          sudo mkdir /var/lib/swtpm-localca
        fi
        sudo chown tss /var/lib/swtpm-localca
        sudo restorecon -rv /var/lib/libvirt
        sudo restorecon -rv /var/log/libvirt
        echo "Giving qemu access to read ISO files from $HOME"
        sudo setfacl -m u:qemu:rx $HOME
        if sudo test ! -f "/etc/libvirt/hooks/qemu"; then
          echo "Adding libvirt qemu hooks"
          sudo wget 'https://raw.githubusercontent.com/PassthroughPOST/VFIO-Tools/master/libvirt_hooks/qemu' -O /etc/libvirt/hooks/qemu
          sudo chmod +x /etc/libvirt/hooks/qemu
          sudo grep -A1 -B1 "# Add" /etc/libvirt/hooks/qemu | sed 's/^# //g'
          if sudo test ! -d "/etc/libvirt/hooks/qemu.d"; then
            sudo mkdir /etc/libvirt/hooks/qemu.d
          fi
        fi
        echo 'Per-user virt setup applied.'
    elif [[ "${OPTION,,}" =~ (^enable[[:space:]]vfio|vfio-on) ]]; then
      # Check if we are running on a Steam Deck
      if /usr/libexec/hwsupport/valve-hardware; then
        echo "IOMMU is not supported on Steam Deck"
        exit 0
      fi
      echo "Enabling VFIO..."
      VIRT_TEST=$(rpm-ostree kargs)
      CPU_VENDOR=$(grep "vendor_id" "/proc/cpuinfo" | uniq | awk -F": " '{ print $2 }')
      VENDOR_KARG="unset"
      if [[ ${VIRT_TEST} == *kvm.report_ignored_msrs* ]]; then
        rpm-ostree initramfs --enable
        if [[ ${CPU_VENDOR} == "AuthenticAMD" ]]; then
          VENDOR_KARG="amd_iommu=on"
        elif [[ ${CPU_VENDOR} == "GenuineIntel" ]]; then
          VENDOR_KARG="intel_iommu=on"
        fi
        if [[ ${VENDOR_KARG} == "unset" ]]; then
          echo "Failed to get CPU vendor, exiting..."
          exit 1
        else
          rpm-ostree kargs \
            --append-if-missing="${VENDOR_KARG}" \
            --append-if-missing="iommu=pt" \
            --append-if-missing="rd.driver.pre=vfio-pci" \
            --append-if-missing="vfio_pci.disable_vga=1"
          echo "VFIO will be enabled on next boot, make sure you enable IOMMU, VT-d or AMD-v in your BIOS!"
          echo "Please understand that since this is such a niche use case, support will be very limited!"
          echo 'Use the command "ls-iommu -grk" to get iommu information about your GPUs, use the "--help" flag for more options'
          echo ""
          echo "${b}Systems with multiple GPUs${n}"
          echo "Bind your unused/second GPU device ids to the vfio driver by running"
          echo 'rpm-ostree kargs --append-if-missing="vfio_pci.ids=xxxx:yyyy,xxxx:yyzz"'
          echo "You will require a $(Urllink "https://www.amazon.com/s?k=hdmi+displayport+dummy+plug" "Dummy HDMI/DisplayPort plug (Ghost Adapter)") or hook the GPU"
          echo "to a separate monitor input in order to turn the GPU on when starting the VM."
          echo "NOTE: Your second GPU should be as different as possible from your main GPU and will not be usable by the host after you bind it to the vfio driver!"
          echo ""
          echo "${b}Systems with 1 GPU${n}"
          echo "Once rebooted you can continue setting up whatever scripts and hooks you need"
          echo "to get Single GPU passthrough working, however ${u}you will be on your own${n}."
          echo "${b}Do not ask for support for setting up Single GPU Passthrough, we can not help you!${n}"
        fi
      fi
    elif [[ "${OPTION,,}" =~ (^disable[[:space:]]vfio|vfio-off) ]]; then
      # Check if we are running on a Steam Deck
      if /usr/libexec/hwsupport/valve-hardware; then
        echo "IOMMU is not supported on Steam Deck"
        exit 0
      fi
      echo ""
      echo "Make sure you have ${b}disabled autostart of all VMs using VFIO${n} before continuing!"
      CONFIRM=$(Choose Cancel Continue)
      if [ "$CONFIRM" == "Continue" ]; then
        echo "Disabling VFIO..."
        VFIO_IDS="$(rpm-ostree kargs | sed -E 's/.+(vfio_pci.ids=.+\s)/\1/' | awk '{ print $1 }' | grep vfio_pci.ids)"
        VFIO_IDS_KARG=""
        if [ -n "$VFIO_IDS" ]; then
          echo "Found VFIO ids in kargs, adding the below line to removal list"
          echo "$VFIO_IDS"
          VFIO_IDS_KARG="--delete-if-present=\"$VFIO_IDS\""
        fi
        KVMFR_VAL="$(rpm-ostree kargs | sed -E 's/.+(kvmfr.static_size_mb=.+\s)/\1/' | awk '{ print $1 }' | grep kvmfr.static_size_mb)"
        KVMFR_KARG=""
        if [ -n "$KVMFR_VAL" ]; then
          echo "Found KVMFR static_size_mb in kargs, adding the below line to removal list"
          echo "$KVMFR_VAL"
          KVMFR_KARG="--delete-if-present=\"$KVMFR_VAL\""
        fi
        echo "Removing deprecated dracut modules"
        sudo rm /etc/dracut.conf.d/vfio.conf
        sudo rm /etc/modprobe.d/kvmfr.conf
        rpm-ostree kargs \
        --delete-if-present="iommu=pt" \
        --delete-if-present="iommu=on" \
        --delete-if-present="amd_iommu=on" \
        --delete-if-present="intel_iommu=on" \
        --delete-if-present="rd.driver.pre=vfio-pci" \
        --delete-if-present="vfio_pci.disable_vga=1" \
        --delete-if-present="vfio_pci.disable_vga=0" \
        $VFIO_IDS_KARG \
        $KVMFR_KARG
      fi
    elif [[ "${OPTION,,}" =~ kvmfr ]]; then
      sudo /usr/libexec/bazzite-dx-kvmfr-setup
    elif [[ "${OPTION,,}" =~ (^enable[[:space:]]usb|usbhp-on) ]]; then
      echo "Adding udev rule for USB devices"
      sudo bash -c 'cat << USBHP_UDEV > /etc/udev/rules.d/72-usbhp.rules
    ACTION=="add" SUBSYSTEM=="usb", TAG+="uaccess"
    USBHP_UDEV'
    elif [[ "${OPTION,,}" =~ (^disable[[:space:]]usb|usbhp-off) ]]; then
      sudo bash -c 'rm /etc/udev/rules.d/72-usbhp.rules'
    elif [[ "${OPTION,,}" =~ group ]]; then
      if ! grep -q "^libvirt" /etc/group; then
        grep '^libvirt' /usr/lib/group | sudo tee -a /etc/group > /dev/null
      fi
      sudo usermod -aG libvirt $USER
    fi
