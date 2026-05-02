#!/usr/bin/bash
# Repo isolation validator.
# Ported from ublue-os/aurora with bazzite-mx specific repo additions.
# Build fails if any third-party repo is left with enabled=1.

echo "::group:: ===$(basename "$0")==="

set -eou pipefail

REPOS_DIR="/etc/yum.repos.d"
VALIDATION_FAILED=0
ENABLED_REPOS=()
declare -A CHECKED=()

echo "Validating all repository files are disabled..."

if [[ ! -d "$REPOS_DIR" ]]; then
    echo "Warning: $REPOS_DIR does not exist"
    exit 0
fi

check_repo_file() {
    local repo_file="$1"
    local basename_file
    basename_file=$(basename "$repo_file")

    [[ ! -f "$repo_file" ]] && return 0
    [[ ! -r "$repo_file" ]] && return 0
    CHECKED["$basename_file"]=1

    if grep -q "^enabled=1" "$repo_file" 2>/dev/null; then
        echo "ENABLED: $basename_file"
        ENABLED_REPOS+=("$basename_file")
        VALIDATION_FAILED=1

        echo "   Enabled sections:"
        local section_name=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[.*\]$ ]]; then
                section_name="$line"
            elif [[ "$line" =~ ^enabled=1 ]]; then
                echo "     - $section_name"
            fi
        done < "$repo_file"
    else
        echo "Disabled: $basename_file"
    fi
}

echo ""
echo "Checking COPR repositories (standard naming)..."
echo "NOTE: With secure isolated installation, NO COPRs should be globally enabled!"
for repo in "$REPOS_DIR"/_copr:copr.fedorainfracloud.org:*.repo; do
    [[ -f "$repo" ]] && check_repo_file "$repo"
done

echo ""
echo "Checking COPR repositories (non-standard naming)..."
for repo in "$REPOS_DIR"/_copr_*.repo; do
    [[ -f "$repo" ]] && check_repo_file "$repo"
done

echo ""
echo "Checking third-party repositories (bazzite-mx + bazzite + aurora known)..."
OTHER_REPOS=(
    "fedora-multimedia.repo"
    "tailscale.repo"
    "vscode.repo"
    "docker-ce.repo"
    "gh-cli.repo"
    "mozilla.repo"
    "fedora-cisco-openh264.repo"
    "fedora-coreos-pool.repo"
    "terra.repo"
)

for repo_name in "${OTHER_REPOS[@]}"; do
    repo_path="$REPOS_DIR/$repo_name"
    if [[ -f "$repo_path" ]]; then
        check_repo_file "$repo_path"
    fi
done

echo ""
echo "Checking RPM Fusion repositories..."
for repo in "$REPOS_DIR"/rpmfusion-*.repo; do
    [[ -f "$repo" ]] && check_repo_file "$repo"
done

# Informational catch-all: list every .repo file not covered by the
# explicit lists above WITHOUT failing the build. Core Fedora/Bazzite
# repos (fedora.repo, fedora-updates.repo, terra-mesa.repo, etc.) are
# legitimately enabled=1 and must stay that way.
#
# Purpose: during PR review, this section makes it visible whether a
# new repo file appeared in the image without being registered in
# OTHER_REPOS. If you add a third-party repo, also add it to OTHER_REPOS
# so it gets hard-enforced disabled instead of just listed here.
echo ""
echo "Informational: other .repo files seen in the image (not enforced)..."
for repo in "$REPOS_DIR"/*.repo; do
    [[ -f "$repo" ]] || continue
    basename_file=$(basename "$repo")
    [[ -n "${CHECKED[$basename_file]:-}" ]] && continue
    if grep -q "^enabled=1" "$repo" 2>/dev/null; then
        echo "  enabled=1: $basename_file"
    else
        echo "  enabled=0: $basename_file"
    fi
done

echo ""
echo "======================================"
if [[ $VALIDATION_FAILED -eq 1 ]]; then
    echo "VALIDATION FAILED"
    echo "======================================"
    echo ""
    echo "The following repositories are still ENABLED:"
    for repo in "${ENABLED_REPOS[@]}"; do
        echo "  - $repo"
    done
    exit 1
fi

echo "::endgroup::"
