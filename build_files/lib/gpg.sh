#!/usr/bin/env bash
# Vendor signing keys, pinned on purpose: the key ships in the repo, its
# .repo reads it with gpgkey=file://, and the build asserts the fingerprint
# before the first install. A rotation is a new key file plus a new line in
# the table. Sourced by lib/env.sh and tests/lib.sh.

# KEY_FPR[<key file in the image>]=<primary key fingerprint>, each read with
# `gpg --show-keys` on the file downloaded from the URL named above it.
declare -A KEY_FPR=(
    # "Docker Release (CE rpm) <docker@docker.com>"
    # download.docker.com/linux/fedora/gpg
    ["/etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce"]=060A61C51B558A7F742B77AAC52FEB6B621E9F35
)

# The primary key's fingerprint of an armored key file, 40 upper-case hex
# digits. gpg gets a throw-away home so nothing lands under /root.
key_fingerprint() {
    local file=$1 home

    home=$(mktemp -d)
    GNUPGHOME=$home gpg --batch --quiet --with-colons --show-keys "$file" 2> /dev/null \
        | awk -F: '$1 == "fpr" { print $10; exit }'
    rm -rf "$home"
}

# The fingerprint defaults to the table; a file the table does not know is a
# build error, so no key enters the image unpinned.
assert_key_fingerprint() {
    local file=$1 expected=${2:-${KEY_FPR[$1]:-}} found

    if [ -z "$expected" ]; then
        fail_build "key $file: no fingerprint pinned in lib/gpg.sh"
    fi

    found=$(key_fingerprint "$file")

    if [ -z "$found" ]; then
        fail_build "key $file: no fingerprint readable"
    fi

    if [ "$found" != "$expected" ]; then
        fail_build "key $file: fingerprint $found, expected $expected"
    fi

    log "key $file: fingerprint $found"
}
