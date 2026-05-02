#!/usr/bin/bash
# DX block 47: install rpmfusion-nonfree-release per shippare le GPG
# keys + i .repo files di RPM Fusion non-free senza vendoring statico.
#
# Approccio scelto invece di vendoreare i `.repo` e la key in
# `system_files/`:
#  - Le GPG keys si auto-aggiornano via `bootc upgrade` standard
#    quando RPM Fusion rilascia nuova versione del pacchetto release
#    (ruotato raramente, ma quando capita lo prendiamo gratis).
#  - Future-proof: il pacchetto include già le key per Fedora 45/46
#    e rawhide. Niente debt manutenzione al rebase Bazzite.
#  - Trust model: la key del pacchetto è firmata dalla Fedora master
#    key, già fidata da Bazzite (transitive trust via signed rpm).
#
# I `.repo` arrivano `enabled=1` da upstream (default RPM Fusion).
# Noi li disabilitiamo subito per allinearli al pattern del progetto
# (`enabled=0` baseline + `--enablerepo=` puntuale a build, oppure
# abilitato runtime via ricetta ujust per install opt-in).

echo "::group:: ===$(basename "$0")==="

set -euxo pipefail

dnf5 -y install \
    "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

# Disable tutte le main section dei .repo shipped dal pacchetto.
# `g` flag necessario perché ogni file ha 3 sezioni (main + debuginfo
# + source), tutte con enabled=1 su release/updates main, enabled=0
# su debuginfo/source. Lo `g` flippa solo le main (le altre sono già 0).
sed -i 's/^enabled=1/enabled=0/g' \
    /etc/yum.repos.d/rpmfusion-nonfree.repo \
    /etc/yum.repos.d/rpmfusion-nonfree-updates.repo \
    /etc/yum.repos.d/rpmfusion-nonfree-updates-testing.repo

echo "::endgroup::"
