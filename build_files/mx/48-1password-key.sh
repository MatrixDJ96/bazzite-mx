#!/usr/bin/bash
# MX block 48: fetch della GPG key 1Password ad ogni build.
#
# Approccio scelto invece del vendoring statico in
# `system_files/etc/pki/rpm-gpg/1password.asc`:
#  - bazzite-mx si rebuilda hourly via watch-upstream → la key è
#    sempre fresh, no manual rotation lato nostro quando 1Password
#    ruota la key (la prima rebuild la cattura).
#  - 1Password non shippa un pacchetto `release` rpm upstream
#    (a differenza di RPM Fusion in 47-*), quindi non c'è
#    un'alternativa "via dnf install". Build-time fetch è il path
#    naturale.
#  - Trust model: HTTPS endpoint `downloads.1password.com`
#    (ufficiale, citato nella loro doc Linux). TLS verificato dal
#    container build CI.
#
# Il file `.repo` di 1Password rimane vendored in
# `system_files/etc/yum.repos.d/1password.repo` perché è policy
# nostra (enabled=0, repo_gpgcheck=1) e cambia raramente — la key
# è la rotating piece, non la config.

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

KEY_URL=https://downloads.1password.com/linux/keys/1password.asc
KEY_PATH=/etc/pki/rpm-gpg/1password.asc

curl -fsSL "$KEY_URL" -o "$KEY_PATH"
chmod 0644 "$KEY_PATH"

# Sanity check: PGP block valido + non-empty. Se 1Password sostituisce
# il file con qualcosa di diverso (es. errore HTML 404 o redirect), la
# build fallisce qui invece di a runtime utente.
[ -s "$KEY_PATH" ] || { echo "FAIL: $KEY_PATH empty"; exit 1; }
grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' "$KEY_PATH" || {
    echo "FAIL: $KEY_PATH non sembra un PGP key block"
    exit 1
}

echo "::endgroup::"
