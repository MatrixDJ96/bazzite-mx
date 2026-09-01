# vim: set ft=make :
#
# 96-bazzite-mx-overrides.just — bazzite-mx OVERRIDE delle recipe ujust
# upstream. Ogni recipe qui rimpiazza una recipe omonima di Bazzite, che
# `build_files/mx/55-justfile-reconcile.sh` espunge chirurgicamente dai file
# upstream al build (manifest recipe→file). Le recipe net-new (non-override)
# stanno invece in 95-bazzite-mx.just.

# setup-virtualization — bazzite-mx OVERRIDE of Bazzite's upstream
# virtualization recipe.
#
# Bazzite's own `setup-virtualization` is flatpak-only (commit 8f1c46b4):
# `virt-on` installs the org.virt_manager.virt-manager flatpak (+ QEMU
# extension) whenever `flatpak info` misses it — on bazzite-mx that branch
# would always fire, duplicating the build-time RPM and fighting the
# flatpak blocklist. The full recipe (VFIO / kvmfr / usbhp / group) lives
# on in bazzite-dx's 84-bazzite-virt.just override, which this file tracks.
# Relative to that bazzite-dx recipe, this one drops:
#   - the `! rpm -q virt-manager` gate and the `flatpak install
#     org.virt_manager.virt-manager` line (RPM is the source of truth;
#     the flatpak is blocklisted in 21-virt-manager-flatpak-exclude.sh);
#   - the kvm.ignore_msrs / kvm.report_ignored_msrs kargs (shipped as
#     module options in /usr/lib/modprobe.d/bazzite-mx-kvm.conf);
#   - the `bazzite-libvirtd-setup.service` enable (libvirtd.service is
#     enabled at build time in 20-virtualization.sh);
#   - the virt-off `flatpak uninstall` path;
#   - the `kvm.report_ignored_msrs` karg sentinel gating vfio-on (that
#     "virt setup ran" marker: the KVM tuning here is modprobe.d options,
#     so no such karg exists and vfio-on proceeds unconditionally).
# The kvmfr / usbhp / group blocks are kept verbatim from bazzite-dx,
# including its `/usr/libexec/bazzite-dx-kvmfr-setup` helper, vendored
# byte-identical in system_files/usr/libexec/. The VFIO blocks carry five
# deliberate deviations, so that vfio-off is a complete revert of vfio-on
# (all five verified live on bazzite-mx 44.20260802, ldesktop-matrix):
#   - vfio-off builds its removal list as a bash array. Upstream builds
#     two of those arguments as strings holding literal double quotes
#     (`--delete-if-present=\"$VAL\"`); expanding a variable performs no
#     quote removal, so rpm-ostree gets a karg NAME with the quotes in
#     it, matches nothing, and — since --delete-if-present is silent on
#     an absent karg — reports nothing. That hits exactly the two
#     host-specific kargs, vfio_pci.ids and kvmfr.static_size_mb, so a
#     multi-GPU host reverting VFIO kept its GPU bound to vfio-pci.
#   - vfio-off finds those two kargs by splitting the karg line and
#     matching an anchored pattern. Upstream's `sed -E
#     's/.+(vfio_pci.ids=.+\s)/\1/'` needs a space AFTER the value, so a
#     karg sitting last on the line never matches: sed then emits the
#     line untouched, awk takes field 1 and grep returns empty, which
#     reads as "this host has no ids". Both failures produce the same
#     symptom, which is why one hid the other.
#   - vfio-off passes `rm -f`: /etc/dracut.conf.d/vfio.conf is written by
#     nobody (upstream included — it is residue from an older recipe), so
#     the plain `rm` fails mid-cleanup and reads as a failed revert.
#   - vfio-on drops `rpm-ostree initramfs --enable`: no VFIO input exists
#     for a local regeneration to consume, and the image already bakes
#     the modules in via force_drivers in
#     /usr/lib/dracut/dracut.conf.d/80-vfio.conf. Upstream never switches
#     it back off, so every later `rpm-ostree upgrade` pays a
#     multi-minute regeneration traceable to a VFIO setup long reverted.
#   - vfio-on drops the `rd.driver.pre=vfio-pci` karg: that same
#     force_drivers line writes etc/cmdline.d/20-force_drivers.conf
#     INSIDE the initramfs, which supplies `rd.driver.pre=vfio
#     vfio_iommu_type1 vfio_pci` on its own — visible in the
#     dracut-cmdline journal line, absent from /proc/cmdline. vfio-off
#     keeps deleting it, since hosts configured by an earlier version of
#     this recipe carry it in their kargs.
# The virt-on branch additionally reconciles the state such an earlier
# version left behind: the kvm kargs and the initramfs regeneration.

# Setup and configure virtualization and vfio
[group("system")]
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
      echo "  NOTE: KVM options (kvm.ignore_msrs / kvm.report_ignored_msrs) and"
      echo "        libvirtd.service are pre-applied at build time on"
      echo "        bazzite-mx — no virt-off path; uninstall the image"
      echo "        if you don't want virt support. 'virt-on' also clears"
      echo "        those kargs when an earlier setup left them behind."
      echo "  NOTE: the vfio, vfio_pci and vfio_iommu_type1 modules ship in"
      echo "        the image initramfs, so they load with or without"
      echo "        'vfio-on'. What binds a device to vfio-pci is the"
      echo "        vfio_pci.ids= karg, and that stays manual either way."
      exit 0
    elif [ "$OPTION" == "" ]; then
      echo "${bold}Virtualization Setup${normal}"
      echo "NOTE: virt-manager (RPM), KVM options and libvirtd are pre-applied at build time."
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
        # Reconcile the state a superseded version of this recipe (and
        # bazzite-dx's virt-on / vfio-on) left on this host. Each item is
        # acted on only when actually present, so a clean host makes no
        # privileged call and gets no pending deployment. This is the
        # branch that reaches BOTH kinds of host: one keeping its VFIO
        # setup never runs vfio-off, so a revert-side cleanup would miss
        # it entirely.
        CURRENT_KARGS="$(rpm-ostree kargs)"
        STALE_KARGS=()
        # bazzite-mx ships this KVM tuning as module options in
        # /usr/lib/modprobe.d/bazzite-mx-kvm.conf, so a host carrying the
        # kargs too applies the same setting through two mechanisms.
        for STALE_KARG in "kvm.ignore_msrs=1" "kvm.report_ignored_msrs=0"; do
          if [[ " ${CURRENT_KARGS} " == *" ${STALE_KARG} "* ]]; then
            STALE_KARGS+=(--delete-if-present="${STALE_KARG}")
          fi
        done
        if [ ${#STALE_KARGS[@]} -gt 0 ]; then
          echo "Removing KVM kargs superseded by /usr/lib/modprobe.d/bazzite-mx-kvm.conf"
          rpm-ostree kargs "${STALE_KARGS[@]}"
        fi
        # An earlier vfio-on ran `rpm-ostree initramfs --enable` with no
        # arguments and nothing ever switched it back off, so every later
        # `rpm-ostree upgrade` pays a multi-minute regeneration. Undo
        # exactly that shape: a host whose regeneration carries custom
        # arguments set it up for its own reasons and is left alone. Read
        # from the JSON, never from the prose of `rpm-ostree initramfs`,
        # whose wording is localized. Deployment 0 is the one that boots
        # next — the same one `rpm-ostree initramfs` reports on, so a
        # second run in a row reads the state the first run just staged.
        OSTREE_STATUS="$(rpm-ostree status --json)"
        REGEN="$(jq -r '.deployments[0] | ."regenerate-initramfs"' <<< "$OSTREE_STATUS")"
        REGEN_ARGC="$(jq -r '.deployments[0] | ."initramfs-args" | length' <<< "$OSTREE_STATUS")"
        if [ "$REGEN" == "true" ] && [ "$REGEN_ARGC" == "0" ]; then
          echo "Disabling the argument-less initramfs regeneration an earlier vfio-on left on"
          rpm-ostree initramfs --disable
        fi
        echo 'Per-user virt setup applied.'
    elif [[ "${OPTION,,}" =~ (^enable[[:space:]]vfio|vfio-on) ]]; then
      # Check if we are running on a Steam Deck
      if /usr/libexec/hwsupport/valve-hardware; then
        echo "IOMMU is not supported on Steam Deck"
        exit 0
      fi
      echo "Enabling VFIO..."
      CPU_VENDOR=$(grep "vendor_id" "/proc/cpuinfo" | uniq | awk -F": " '{ print $2 }')
      VENDOR_KARG="unset"
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
          --append-if-missing="vfio_pci.disable_vga=1"
        echo "VFIO will be enabled on next boot, make sure you enable IOMMU, VT-d or AMD-v in your BIOS!"
        echo "The vfio modules are in the image initramfs and load either way; these kargs"
        echo "set up the IOMMU, and binding a device to vfio-pci stays manual (see below)."
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
        # A bash array, so every argument reaches rpm-ostree with its
        # quoting already applied. Building them as strings that hold
        # literal double quotes (upstream does that for the two dynamic
        # ones) hands rpm-ostree a karg NAME with the quotes inside it:
        # it matches nothing, and --delete-if-present says nothing about
        # a karg it does not find.
        KARG_ARGS=(
          --delete-if-present="iommu=pt"
          --delete-if-present="iommu=on"
          --delete-if-present="amd_iommu=on"
          --delete-if-present="intel_iommu=on"
          # vfio-on stopped appending this one — the image initramfs
          # supplies it — but hosts set up by an earlier version of the
          # recipe still carry it in their kargs.
          --delete-if-present="rd.driver.pre=vfio-pci"
          --delete-if-present="vfio_pci.disable_vga=1"
          --delete-if-present="vfio_pci.disable_vga=0"
        )
        # One karg per line, then an anchored match. Upstream instead
        # runs `sed -E 's/.+(vfio_pci.ids=.+\s)/\1/'`, whose \s demands a
        # space AFTER the value: when the karg is last on the line the
        # match fails, sed passes the whole line through, awk takes field
        # 1 (an unrelated karg) and grep yields nothing — reporting "no
        # ids on this host" for a host that has them.
        KARG_LINES="$(rpm-ostree kargs | tr ' ' '\n')"
        VFIO_IDS="$(grep '^vfio_pci\.ids=' <<< "$KARG_LINES")"
        if [ -n "$VFIO_IDS" ]; then
          echo "Found VFIO ids in kargs, adding the below line to removal list"
          echo "$VFIO_IDS"
          KARG_ARGS+=(--delete-if-present="$VFIO_IDS")
        fi
        KVMFR_VAL="$(grep '^kvmfr\.static_size_mb=' <<< "$KARG_LINES")"
        if [ -n "$KVMFR_VAL" ]; then
          echo "Found KVMFR static_size_mb in kargs, adding the below line to removal list"
          echo "$KVMFR_VAL"
          KARG_ARGS+=(--delete-if-present="$KVMFR_VAL")
        fi
        # -f: no current recipe writes /etc/dracut.conf.d/vfio.conf, so
        # on most hosts it is simply absent and a plain rm would fail
        # mid-cleanup, reading as a failed revert.
        echo "Removing deprecated dracut modules"
        sudo rm -f /etc/dracut.conf.d/vfio.conf
        sudo rm -f /etc/modprobe.d/kvmfr.conf
        rpm-ostree kargs "${KARG_ARGS[@]}"
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
    else
      # The Bazzite Portal (yafti) drives this recipe from
      # /usr/share/yafti/yafti.yml, which offers 'virt-off' -- an action this
      # override deliberately does not carry. Without this branch the chain
      # fell through and exited 0, so the Portal reported success for a no-op.
      echo "${red}${b}'$OPTION' is not supported on bazzite-mx${n}"
      echo "The KVM options, libvirtd and virt-manager are applied at build time,"
      echo "so there is no virt-off path: uninstall the image if you don't want"
      echo "virt support. Run ${b}ujust setup-virtualization help${n} for the"
      echo "options this recipe does carry."
      exit 1
    fi

# setup-sunshine — bazzite-mx OVERRIDE of Bazzite's upstream Sunshine recipe.
#
# bazzite-mx ships Sunshine as a system RPM (build_files/mx/65-sunshine.sh,
# community pvermeer/sunshine COPR) with the user unit
# `app-dev.lizardbyte.app.Sunshine.service` (alias `sunshine.service`).
# Upstream's recipe (flatpak-flavored since commit e05b27f8, brew kept for
# the Deck-oriented `enable-beta` path) manages the
# dev.lizardbyte.app.Sunshine flatpak: on bazzite-mx its `enable`
# would install a flatpak duplicating the RPM. This recipe drops the
# flatpak/brew/Cellar handling, `enable-beta`, `update`, and `uninstall`
# (Sunshine is part of the base image; removal is `rpm-ostree override
# remove sunshine`, noted in `help`), keeping `status`, `enable`,
# `disable`, `portal`, `help`. The `virtual-monitor` action is ported
# from upstream (bazzite 55e6e852, KWin-only): its helper scripts
# sunshine-start-vmon / sunshine-stop-vmon ship byte-identical in
# system_files/usr/libexec/, and the function keeps upstream's flatpak
# and native config branches — on bazzite-mx the native branch applies
# (RPM Sunshine, config in ~/.config/sunshine/).

# Setup and configure Sunshine Game Streaming host. Options: status | enable | disable | portal | virtual-monitor | help
[group("gaming")]
setup-sunshine ACTION="":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    OPTION={{ ACTION }}
    SUNSHINE_UNIT="app-dev.lizardbyte.app.Sunshine.service"

    get_status_token() {
      local service_state
      service_state="$(systemctl is-enabled --user $SUNSHINE_UNIT 2>/dev/null || true)"
      if [[ "$service_state" == "enabled" ]]; then
        echo "enable"
      else
        echo "disable"
      fi
    }

    press_any_key() {
      echo "Press Enter to continue..."
      read -r
    }

    virtual-monitor() {
      local FLATPAK_VMON_APP='{
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
                "do": "sh -c \"flatpak-spawn --host --env=SUNSHINE_CLIENT_WIDTH=\\\"${SUNSHINE_CLIENT_WIDTH}\" --env=SUNSHINE_CLIENT_HEIGHT=\\\"${SUNSHINE_CLIENT_HEIGHT}\" --env=SUNSHINE_CLIENT_FPS=\\\"${SUNSHINE_CLIENT_FPS}\\\" --env=QT_QPA_PLATFORM=wayland --env=WAYLAND_DISPLAY=wayland-0 --env=XDG_RUNTIME_DIR=/run/user/1000 --env=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus /usr/libexec/sunshine-start-vmon\"",
                "undo": "sh -c \"flatpak-spawn --host env QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus /usr/libexec/sunshine-stop-vmon\""
            }
        ],
        "wait-all": true
      }'
      local NORMAL_VMON_APP='{
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
      local FLATPAK_APP_CONF="$HOME/.var/app/dev.lizardbyte.app.Sunshine/config/sunshine/apps.json"
      local NORMAL_APP_CONF="$HOME/.config/sunshine/apps.json"
      if [[ -f "$FLATPAK_APP_CONF" ]]; then
        local APP_CONF="$FLATPAK_APP_CONF"
        local VMON_APP="$FLATPAK_VMON_APP"
      elif [[ -f "$NORMAL_APP_CONF" ]]; then
        local APP_CONF="$NORMAL_APP_CONF"
        local VMON_APP="$NORMAL_VMON_APP"
      else
        echo "No app config found! Is Sunshine installed?"
        exit 1
      fi
      local MON_OPTION=$(Choose "Add Virtual Monitor" "Fix Error 503" "Go Back" "Exit")
      case "$MON_OPTION" in
        "Add Virtual Monitor")
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
          ' "$APP_CONF" > "$TMP_FILE"
          mv "$TMP_FILE" "$APP_CONF"
          echo "Successfully added/updated 'Virtual Monitor' in $APP_CONF"
          echo -e "[Service]\nExecStopPost=/usr/libexec/sunshine-stop-vmon" | systemctl --user edit "$SUNSHINE_UNIT" --stdin
          systemctl --user daemon-reload
          echo "Remember to set the Capture Method to ${bold}KWin Screencast${normal}."
          echo "${bold}Restart Sunshine${normal} for changes to takes effect."
          xdg-open "https://localhost:47990/troubleshooting"
          press_any_key
        ;;
        "Fix Error 503")
          mkdir -p "$HOME/.config/environment.d"
          echo "KWIN_WAYLAND_NO_PERMISSION_CHECKS=1" > "$HOME/.config/environment.d/98-kwin-no-permission-checks.conf"
          echo -n "Wrote in $HOME/.config/environment.d/98-kwin-no-permission-checks.conf: "
          cat "$HOME/.config/environment.d/98-kwin-no-permission-checks.conf"
        ;;
        "Go Back")
          ujust setup-sunshine
        ;;
        *)
        ;;
      esac
    }

    if [ "$OPTION" == "help" ]; then
      echo "Usage: ujust setup-sunshine <option>"
      echo "  <option>: Specify the quick option to skip the prompt"
      echo "  Use 'status' to print the current service state"
      echo "  Use 'enable' to enable+start the Sunshine user service"
      echo "  Use 'disable' to stop+disable the Sunshine user service"
      echo "  Use 'portal' to open the Sunshine management portal in a browser"
      echo "  Use 'virtual-monitor' to configure a virtual monitor for headless streaming (KWin only)"
      echo "  Use 'exit' to exit without making changes"
      echo ""
      echo "${b}Notes${n}:"
      echo "  - Sunshine is shipped at build time as a system RPM (community pvermeer/sunshine COPR)."
      echo "    Updates flow automatically with ${b}bootc upgrade${n} / ${b}ujust update${n}."
      echo "  - To remove Sunshine entirely: ${b}rpm-ostree override remove sunshine${n}, then reboot."
      echo "  - Default service state on a fresh image: ${b}disabled${n} (Aurora pattern)."
      echo "  - Port forwarding for streaming over the internet: 47984 (HTTPS), 47989 (HTTP),"
      echo "    47998-48000/UDP (video/audio/control), 48010 (RTSP)."
      exit 0
    elif [ "$OPTION" == "status" ]; then
      echo "$(get_status_token)"
      exit 0
    elif [ "$OPTION" == "" ]; then
      case "$(get_status_token)" in
        "enable")
          SERVICE_STATE="${green}${b}Enabled${n}"
          ;;
        *)
          SERVICE_STATE="${yellow}${b}Disabled${n}"
          ;;
      esac
      echo "Sunshine user service is $SERVICE_STATE"
      OPTION=$(Choose "Enable" "Disable" "Open Portal" "Virtual Monitor" "Exit")
    fi

    # ^enable$ / ^disable$, anchored at both ends: the Bazzite Portal drives
    # this recipe from /usr/share/yafti/yafti.yml, which still offers
    # upstream's flatpak-era buttons. An unanchored ^enable made the
    # 'enable-beta' button run the plain RPM enable path, while 'update' and
    # 'uninstall' matched nothing, fell through and exited 0 -- so the Portal
    # reported success for a no-op. The Choose menu feeds this the same
    # lowercased tokens ('enable', 'disable', 'open portal', ...).
    if [[ "${OPTION,,}" =~ ^enable$ ]]; then
      echo "Enabling Sunshine user service ($SUNSHINE_UNIT)..."
      systemctl --user enable --now "$SUNSHINE_UNIT"
      echo ""
      echo "Sunshine is now ${green}${b}running${n}."
      echo "Open the management portal: ${b}ujust setup-sunshine portal${n} (or https://localhost:47990)"
      echo "First-time setup will ask you to create a credential pair to pair Moonlight clients."
    elif [[ "${OPTION,,}" =~ ^disable$ ]]; then
      echo "Disabling Sunshine user service ($SUNSHINE_UNIT)..."
      systemctl --user disable --now "$SUNSHINE_UNIT" || true
      echo "Sunshine is now ${yellow}${b}stopped${n}."
    elif [[ "${OPTION,,}" =~ ^(portal|open) ]]; then
      echo "Opening Sunshine management portal..."
      xdg-open https://localhost:47990
    elif [[ "${OPTION,,}" =~ ^virtual([- ])monitor ]]; then
      virtual-monitor
    elif [[ "${OPTION,,}" =~ ^exit ]]; then
      echo "Exiting without making changes."
      exit 0
    else
      echo "${red}${b}'$OPTION' is not supported on bazzite-mx${n}"
      echo "Sunshine ships here as a system RPM, not as the flatpak upstream's"
      echo "recipe manages: updates arrive with ${b}bootc upgrade${n} / ${b}ujust update${n},"
      echo "removal is ${b}rpm-ostree override remove sunshine${n}, and there is no"
      echo "Beta build. Run ${b}ujust setup-sunshine help${n} for the supported options."
      exit 1
    fi

# Install JetBrains Toolbox | https://www.jetbrains.com/toolbox-app/
#
# bazzite-mx OVERRIDE della recipe brew upstream (82-bazzite-apps.just).
# Upstream installa via Homebrew cask (ublue-os/tap → jetbrains-toolbox-linux);
# qui il metodo non-brew ex-Aurora/Bluefin (bluefin PR #397, maturato in #2645 /
# aurora #581; Aurora è poi tornata al cask brew — divergenza #20): risolve
# l'ultima build dalla JetBrains data-services API, scarica + verifica sha256
# il tarball, installa in ~/.local/share/JetBrains/ToolboxApp/ e lancia
# (self-setup: desktop entry, auto-update). Nessun Homebrew, nessun Cellar.
# Gira come utente ($HOME) — niente sudo. jq è nell'immagine base.
#
# Rieseguibile: reinstalla sempre l'ultima build (upgrade/riparazione).
# `mv dir/*` su una ToolboxApp/ esistente fallisce ("Directory not empty":
# mv non fonde directory), quindi il vecchio albero viene rimosso e la
# directory versionata rinominata in blocco. Un Toolbox in esecuzione
# sopravvive sul vecchio inode (unlink POSIX) e prende i nuovi file al
# riavvio. Il trap EXIT rimuove il workdir (~1,5 GiB su /tmp tmpfs) su ogni
# uscita, errori inclusi.
[group("apps")]
install-jetbrains-toolbox:
    #!/usr/bin/bash
    set -eo pipefail
    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT
    cd "$workdir"
    echo "Resolving latest JetBrains Toolbox release..."
    curl -sSfL -o releases.json "https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release"
    BUILD_VERSION=$(jq -r '.TBA[0].build' ./releases.json)
    DOWNLOAD_LINK=$(jq -r '.TBA[0].downloads.linux.link' ./releases.json)
    CHECKSUM_LINK=$(jq -r '.TBA[0].downloads.linux.checksumLink' ./releases.json)
    echo "Installing JetBrains Toolbox ${BUILD_VERSION}..."
    curl -sSfL -O "${DOWNLOAD_LINK}"
    curl -sSfL "${CHECKSUM_LINK}" | sha256sum -c
    tar zxf "jetbrains-toolbox-${BUILD_VERSION}.tar.gz"
    APP_DIR="${HOME}/.local/share/JetBrains/ToolboxApp"
    mkdir -p "${APP_DIR%/*}"
    rm -rf "${APP_DIR}"
    mv "jetbrains-toolbox-${BUILD_VERSION}" "${APP_DIR}"
    echo "Launching JetBrains Toolbox..."
    "${APP_DIR}/bin/jetbrains-toolbox" &> /dev/null &
