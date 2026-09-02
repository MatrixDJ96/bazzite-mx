#!/usr/bin/env bash
# Vendor signing keys, pinned on purpose: the key ships in the repo, its
# .repo reads it with gpgkey=file://, and the build asserts the fingerprint
# before the first install. A rotation is a new key file plus a new line here.
#
# KEY_FPR[<key file in the image>]=<primary key fingerprint>, each read with
# `gpg --show-keys` on the file downloaded from the URL named.
declare -A KEY_FPR=(
    # "Docker Release (CE rpm) <docker@docker.com>", download.docker.com/linux/fedora/gpg
    ["/etc/pki/rpm-gpg/RPM-GPG-KEY-docker-ce"]=060A61C51B558A7F742B77AAC52FEB6B621E9F35
    # "Microsoft (Release signing) <gpgsecurity@microsoft.com>", packages.microsoft.com/keys/microsoft.asc
    ["/etc/pki/rpm-gpg/RPM-GPG-KEY-microsoft"]=BC528686B50D79E339D3721CEB3E94ADBE1229CF
    # "jdxcode_mise (None) <jdxcode#mise@copr.fedorahosted.org>", valid to 2030-07-19,
    # download.copr.fedorainfracloud.org/results/jdxcode/mise/pubkey.gpg
    ["/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-jdxcode-mise"]=9504792D1F9CCA1514FD1DEC8497A816C83E991C
    # "Code signing for 1Password <codesign@1password.com>", downloads.1password.com/linux/keys/1password.asc
    ["/etc/pki/rpm-gpg/RPM-GPG-KEY-1password"]=3FEF9748469ADBE15DA7CA80AC2D62742012EA22
    # "lizardbyte_stable (None) <lizardbyte#stable@copr.fedorahosted.org>",
    # download.copr.fedorainfracloud.org/results/lizardbyte/stable/pubkey.gpg
    ["/etc/pki/rpm-gpg/RPM-GPG-KEY-copr-lizardbyte-stable"]=1827C306E9944D99DF4CACF143B84301E4F68234
)

# key_fingerprint <armored-key-file>: the primary key's fingerprint (40 hex,
# upper case). gpg gets a throw-away home so nothing lands under /root.
key_fingerprint() {
    local home
    home=$(mktemp -d)
    GNUPGHOME=$home gpg --batch --quiet --with-colons --show-keys "$1" 2> /dev/null \
        | awk -F: '$1 == "fpr" { print $10; exit }'
    rm -rf "$home"
}

# assert_key_fingerprint <armored-key-file> [<fingerprint>]: the fingerprint
# defaults to the table above; a file the table does not know is a build error.
assert_key_fingerprint() {
    local file=$1 expected=${2:-${KEY_FPR[$1]:-}} got
    [ -n "$expected" ] || die "key $file: no fingerprint pinned in lib/gpg.sh"
    [ -s "$file" ] || die "key $file missing or empty"
    got=$(key_fingerprint "$file")
    [ -n "$got" ] || die "key $file: no fingerprint readable"
    [ "$got" = "$expected" ] || die "key $file: fingerprint $got, expected $expected"
    log "key $file: fingerprint $got"
}
