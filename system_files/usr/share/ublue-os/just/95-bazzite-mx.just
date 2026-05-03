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
# stdout channel keeps install-* output clean (UX bug found 2026-05-03).
#
# `// []` keeps the jq query safe when `.packages` is null (deployment
# with no layered packages) or no booted deployment (e.g. CI container
# without ostree) — both resolve to "no" → install proceeds.
[private]
_pkg_layered pkg:
    @if rpm-ostree status --json | jq -e --arg p "{{ pkg }}" '.deployments[] | select(.booted == true) | (.packages // []) | index($p)' > /dev/null; then echo yes; else echo no; fi

# Install Discord from RPM Fusion non-free (rpm-ostree layer)
[group("apps")]
install-discord:
    #!/usr/bin/env bash
    set -eo pipefail

    cat <<'EOF'
    {{ YELLOW }}This recipe will proceed to {{ BOLD }}layer{{ NORMAL }} {{ YELLOW }}Discord{{ NORMAL }} from RPM Fusion non-free.
    {{ YELLOW }}If future updates start to fail, run "{{ BOLD }}rpm-ostree reset{{ NORMAL }}{{ YELLOW }}" to drop the layer.{{ NORMAL }}
    {{ YELLOW }}See https://docs.bazzite.gg/Installing_and_Managing_Software/rpm-ostree/#major-caveats-using-rpm-ostree{{ NORMAL }}
    EOF

    if [ "$(just _pkg_layered discord)" = "yes" ]; then
        echo "Discord is already layered, skipping."
        exit 0
    fi

    repo_path="/etc/yum.repos.d/rpmfusion-nonfree-updates.repo"
    if grep -q "^enabled=1" "$repo_path"; then
        echo "RPM Fusion non-free updates is already enabled, skipping enable step."
    else
        echo "Enabling RPM Fusion non-free updates main section."
        # `0,/^enabled=0/` limits the edit to the FIRST match in the
        # file: the main section. The `-debuginfo` and `-source`
        # sections stay enabled=0 (we don't want them auto-enabled).
        sudo sed -i '0,/^enabled=0/{s/^enabled=0/enabled=1/}' "$repo_path"
    fi

    echo "Installing discord (rpm-ostree layer)..."
    sudo rpm-ostree install -y discord
    echo "Complete. Reboot to apply: systemctl reboot"

# Install 1Password from the official 1Password rpm repo (rpm-ostree layer)
[group("apps")]
install-1password:
    #!/usr/bin/env bash
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
    if grep -q "^enabled=1" "$repo_path"; then
        echo "1Password repository is already enabled, skipping enable step."
    else
        echo "Enabling 1Password repository."
        # Single-section file — simple sed, no range pattern needed.
        sudo sed -i 's/^enabled=0/enabled=1/' "$repo_path"
    fi

    echo "Installing 1password (rpm-ostree layer)..."
    sudo rpm-ostree install -y 1password
    echo "Complete. Reboot to apply: systemctl reboot"
