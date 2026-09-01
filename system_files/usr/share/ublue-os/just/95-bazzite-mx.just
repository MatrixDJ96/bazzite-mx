# vim: set ft=make :
#
# 95-bazzite-mx.just — bazzite-mx custom ujust recipes.
#
# Convention:
#  - Private helper recipes prefixed with `_`.
#  - Public recipes grouped via `[group("...")]` for `just --list` UX.
#  - `install-*` recipes follow the Bazzite-DX pattern: layer rpm via
#    rpm-ostree, leave the source repo enabled afterwards so future
#    `bootc upgrade` / `ujust update` runs pull new versions automatically.
#  - Use the `_pkg_layered` helper for idempotency instead of `rpm -q`
#    (rpm -q sees base-image packages too; `_pkg_layered` checks only
#    the rpm-ostree overlay layer of the booted deployment).

# Check if a package is already layered on the booted rpm-ostree
# deployment. Outputs `yes`/`no` on stdout; always exits 0.
# Usage: `if [ "$(just _pkg_layered <pkg>)" = "yes" ]; then ... ; fi`
#
# Stdout-as-boolean instead of exit code: `just` always logs
# `error: Recipe ... failed on line N with exit code 1` when a
# sub-recipe exits ≠ 0, even when wrapped in the caller's `if`. The
# stdout channel keeps install-* output clean.
#
# `// []` keeps the jq query safe when `.packages` is null (deployment
# with no layered packages) or no booted deployment (e.g. CI container
# without ostree) — both resolve to "no" → install proceeds.
[private]
_pkg_layered pkg:
    @if rpm-ostree status --json | jq -e --arg p "{{ pkg }}" '.deployments[] | select(.booted == true) | (.packages // []) | index($p)' > /dev/null; then echo yes; else echo no; fi

# The 1password.repo is vendored under system_files/etc/yum.repos.d/
# with `enabled=0` and is the single source of truth — no override
# section ships in the image. The single-section file is flipped
# enabled=0 -> 1 here with a plain sed.
#
# Bazzite-inherited limit: chaining two rpm-ostree installs without a
# reboot in between fails on the second with "Packages not found" —
# rpm-ostree builds the next deployment on top of the first pending one
# and reads /etc from there, so a runtime sed on live /etc is invisible
# to the second solve.

# Install 1Password from the official rpm repo (rpm-ostree layer)
[group("apps")]
install-1password:
    #!/usr/bin/bash
    set -eo pipefail

    cat <<'EOF'
    {{ YELLOW }}This recipe will proceed to {{ BOLD }}layer{{ NORMAL }} {{ YELLOW }}1Password{{ NORMAL }} from downloads.1password.com.
    {{ YELLOW }}If future updates start to fail, run "{{ BOLD }}rpm-ostree reset{{ NORMAL }}{{ YELLOW }}" to drop the layer.{{ NORMAL }}
    {{ YELLOW }}See https://docs.bazzite.gg/Installing_and_Managing_Software/rpm-ostree/#major-caveats-using-rpm-ostree{{ NORMAL }}
    EOF

    if [ "$(just _pkg_layered 1password)" = "yes" ]; then
        echo "1Password is already layered, skipping."
        exit 0
    fi

    repo_path="/etc/yum.repos.d/1password.repo"
    if ( ! grep -q "enabled=0" "$repo_path" ); then
        echo '1Password repository is already enabled, skipping.'
    else
        echo 'Enabling 1Password repository.'
        sudo sed -i 's@enabled=0@enabled=1@g' "$repo_path"
    fi

    echo 'Installing 1password...'
    sudo rpm-ostree install -y 1password
    echo 'Complete, please reboot to apply changes.'

# Reset the DNF repository configuration to the immutable image defaults
#
# Repo files and Bazzite's config-manager priority/exclude overrides are
# baked into the image. Runtime drift accumulates in two places:
#   - /etc/yum.repos.d/         — install-* recipes flip enabled=0 -> 1
#                                 here; `dnf copr enable` drops files here.
#   - /etc/dnf/repos.override.d/ — `dnf config-manager setopt` writes
#                                 per-repo overrides here.
# This mirrors the factory copies under /usr/etc/ back onto /etc/, so the
# repo config matches a fresh deployment: flipped repos return to
# enabled=0, Bazzite's 99-config_manager.repo is restored, and any .repo
# added at runtime that the image does not ship is removed.
#
# /usr/etc is ostree's pristine /etc for the booted deployment and tracks
# the current image (updates on `bootc upgrade`), so this always means
# "this image's defaults". `rsync -c` compares by content, so the preview
# lists only real drift, not cosmetic mtime differences. Effective
# immediately, no reboot. Layered packages are out of scope — use
# `rpm-ostree reset` for those.

# Reset DNF repos and config-manager overrides to the image defaults
[group("system")]
reset-repos:
    #!/usr/bin/bash
    set -eo pipefail

    cat <<'EOF'
    {{ YELLOW }}This restores the DNF repository configuration to the {{ BOLD }}image defaults{{ NORMAL }}{{ YELLOW }}.{{ NORMAL }}
    {{ YELLOW }}Repos enabled by "{{ BOLD }}ujust install-*{{ NORMAL }}{{ YELLOW }}" are turned back off; runtime-added repos are removed.{{ NORMAL }}
    {{ YELLOW }}Layered packages are NOT touched — use "{{ BOLD }}rpm-ostree reset{{ NORMAL }}{{ YELLOW }}" for those.{{ NORMAL }}
    EOF

    pairs=(
        "/usr/etc/yum.repos.d/:/etc/yum.repos.d/"
        "/usr/etc/dnf/repos.override.d/:/etc/dnf/repos.override.d/"
    )

    restore=(); remove=()
    for pair in "${pairs[@]}"; do
        src="${pair%%:*}"; dst="${pair##*:}"
        [ -d "$src" ] || continue
        while read -r code path; do
            [ -z "$path" ] && continue
            case "$code" in
                \*deleting) remove+=("${dst}${path}") ;;
                [\<\>c]*)   restore+=("${dst}${path}") ;;
            esac
        done < <(rsync -ainc --delete "$src" "$dst" 2>/dev/null)
    done

    if [ ${#restore[@]} -eq 0 ] && [ ${#remove[@]} -eq 0 ]; then
        echo "Repositories already match the image — nothing to reset."
        exit 0
    fi

    echo "The following changes will be applied:"
    for f in "${restore[@]}"; do echo "  {{ BOLD }}restore{{ NORMAL }}  ${f}"; done
    for f in "${remove[@]}";  do echo "  {{ BOLD }}remove {{ NORMAL }}  ${f}"; done

    read -rp "Proceed? [y/N] " ans
    case "$ans" in
        [Yy]*) ;;
        *) echo "Aborted, no changes made."; exit 0 ;;
    esac

    for pair in "${pairs[@]}"; do
        src="${pair%%:*}"; dst="${pair##*:}"
        [ -d "$src" ] || continue
        sudo rsync -aic --delete "$src" "$dst" >/dev/null
    done
    echo "Repository configuration reset to image defaults."

# Set up MSI laptop support: EC kernel modules + the MControlCenter GUI (opt-in)
#
# One recipe for the whole MSI experience. The msi-ec and acpi_ec modules ship
# in the image under /usr/lib/modules/<kver>/updates/ but are NOT autoloaded —
# only MSI laptops benefit, and on non-MSI hardware (or with Secure Boot on,
# since the modules are unsigned) they will not load.
#
# Run with no argument for an interactive menu (status + Enable/Disable), or
# pass a quick option to skip the prompt:
#   enable   load msi-ec + acpi_ec, persist autoload, and layer MControlCenter.
#   disable  unload both modules, drop the autoload, and uninstall the GUI.
#   status   print the current status token (enable/disable).
#   help     print usage.
#
# acpi_ec creates the root-only (0600) /dev/ec character device that
# MControlCenter falls back to when the in-kernel ec_sys debugfs is absent
# (the ogc kernel builds with CONFIG_ACPI_EC_DEBUGFS off). That single device
# carries both fan RPM reads and fan-curve writes — there is no separate
# read-only mode; access is gated by the device permissions and mediated by
# MControlCenter's privileged D-Bus system helper, so no root GUI or udev rule
# is needed. msi-ec and acpi_ec coexist (the kernel serializes EC transactions).
# rpm-ostree GUI install/removal takes effect after a reboot; module load is
# immediate.

# Set up MSI laptop support: EC kernel modules + MControlCenter GUI (opt-in)
[group("hardware")]
setup-msi ACTION="":
    #!/usr/bin/bash
    set -eo pipefail
    source /usr/lib/ujust/ujust.sh

    MODULES_LOAD=/etc/modules-load.d/bazzite-mx-msi.conf
    REPO_PATH=/etc/yum.repos.d/teackot-msi.repo

    # Exit-code wrapper around the shared `_pkg_layered` recipe (its
    # stdout-as-boolean contract keeps the jq query defined in one place).
    layered_package() {
        [ "$(just _pkg_layered "$1")" = "yes" ]
    }

    get_status_token() {
        if [ -f "$MODULES_LOAD" ] && layered_package mcontrolcenter; then
            echo "enable"
        else
            echo "disable"
        fi
    }

    get_current_status() {
        if [ -f "$MODULES_LOAD" ] && layered_package mcontrolcenter; then
            echo "Enabled"
        elif [ -f "$MODULES_LOAD" ] || layered_package mcontrolcenter; then
            echo "Partially Enabled"
        else
            echo "Disabled"
        fi
    }

    enable_msi() {
        echo "${yellow}This recipe loads the ${bold}msi-ec${normal}${yellow} + ${bold}acpi_ec${normal}${yellow} kernel modules and layers ${bold}MControlCenter${normal}${yellow}.${normal}"
        echo "${yellow}If updates start to fail, please use \"${bold}rpm-ostree reset${normal}${yellow}\".${normal}"
        echo "${yellow}See https://docs.bazzite.gg/Installing_and_Managing_Software/rpm-ostree/#major-caveats-using-rpm-ostree${normal}"

        # Persist autoload for both EC modules across reboots.
        printf 'msi-ec\nacpi_ec\n' | sudo tee "$MODULES_LOAD" >/dev/null

        # Load now (this boot).
        if sudo modprobe msi-ec 2>/dev/null; then
            echo "${green}✔${normal} msi-ec loaded."
        else
            echo "${red}✘${normal} msi-ec did not load — check ${bold}sudo dmesg | grep msi_ec${normal} (non-MSI/unsupported board, or Secure Boot on with this module unsigned)."
        fi
        if sudo modprobe acpi_ec 2>/dev/null; then
            echo "${green}✔${normal} acpi_ec loaded — ${bold}/dev/ec${normal} ready for MControlCenter fan control."
        else
            echo "${red}✘${normal} acpi_ec did not load — Secure Boot on with this module unsigned?"
        fi

        # Layer the MControlCenter GUI from the vendored teackot/msi COPR.
        if layered_package mcontrolcenter; then
            echo "MControlCenter is already layered, skipping."
        else
            if grep -q "enabled=0" "$REPO_PATH"; then
                echo 'Enabling teackot/msi COPR.'
                sudo sed -i 's@enabled=0@enabled=1@g' "$REPO_PATH"
            fi
            echo 'Installing mcontrolcenter...'
            sudo rpm-ostree install -y mcontrolcenter
            echo 'Complete, please reboot to apply changes.'
        fi
    }

    disable_msi() {
        sudo rm -f "$MODULES_LOAD"
        sudo modprobe -r acpi_ec 2>/dev/null || true
        sudo modprobe -r msi-ec 2>/dev/null || true
        echo "${green}✔${normal} Modules unloaded and autoload removed."
        if layered_package mcontrolcenter; then
            echo 'Uninstalling mcontrolcenter...'
            sudo rpm-ostree uninstall -y mcontrolcenter
            echo 'Complete, please reboot to apply changes.'
        else
            echo "MControlCenter is not layered."
        fi
    }

    OPTION="{{ ACTION }}"
    if [[ "$OPTION" == "help" ]]; then
        echo "Usage: ujust setup-msi <option>"
        echo "  <option>: Specify the quick option to skip the prompt"
        echo "  Use 'status' to print the current status token"
        echo "  Use 'enable' to load the EC modules and install MControlCenter"
        echo "  Use 'disable' to unload them and uninstall MControlCenter"
        exit 0
    elif [[ "$OPTION" == "status" ]]; then
        get_status_token
        exit 0
    elif [[ "$OPTION" == "enable" ]]; then
        enable_msi
        exit 0
    elif [[ "$OPTION" == "disable" ]]; then
        disable_msi
        exit 0
    elif [[ -z "$OPTION" ]]; then
        current_status=$(get_current_status)
        echo "${bold}MSI laptop support${normal}"
        echo "Current status: $current_status"
        OPTION=$(ugum choose "Enable" "Disable" "Exit without changes")
        case "$OPTION" in
            "Enable")  enable_msi ;;
            "Disable") disable_msi ;;
            *)         echo "No changes made." ;;
        esac
        exit 0
    else
        echo "Usage: ujust setup-msi <enable|disable|status|help>"
        exit 1
    fi
