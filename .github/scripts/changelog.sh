#!/usr/bin/env bash
# The body and the title of a GitHub Release, from what the run resolved. The
# previous release comes from `gh release list`, never from a manifest's
# RepoTags, which an orphan tag would hijack. Every gap is stated in the notes.
#
#   changelog.sh release --release-tag <tag> --out <changelog.md> <env-file>...
#       env-file: image_name, digest, base_name, base_digest, from the build
#                 job. Prints the title on stdout.
#   changelog.sh --self-test
#
# Needs skopeo, oras, gh (GH_TOKEN) and git with the history (fetch-depth 500).
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SBOM_TYPE=application/vnd.spdx+json

# Prints nothing when no published release has the stable tag shape.
previous_tag() {
    local json=$1 current=$2
    jq -r --arg shape "$TAG_SHAPE" --arg cur "$current" '
        [.[] | select(.tagName != $cur and (.tagName | test($shape)) and .isDraft == false)]
        | sort_by(.publishedAt) | last | .tagName // empty' <<< "$json"
}

# "name<TAB>version" per RPM, sorted, one line per name (the syft-json shape).
sbom_packages() {
    local sbom=$1 out=$2
    jq -r '.artifacts[] | select(.type == "rpm") | "\(.name)\t\(.version)"' "$sbom" | sort -u -t $'\t' -k1,1 > "$out"
    [ -s "$out" ] || {
        err "$sbom lists no RPM"
        return 1
    }
}

package_diff() {
    local prev=$1 curr=$2
    join -t $'\t' -a1 -a2 -e MISSING -o '0,1.2,2.2' "$prev" "$curr" | awk -F'\t' '
        $2 == "MISSING" { added = added "- **" $1 "** " $3 " (added)\n"; next }
        $3 == "MISSING" { removed = removed "- **" $1 "** " $2 " (removed)\n"; next }
        $2 != $3 { changed = changed "- **" $1 "** " $2 " → " $3 "\n" }
        END { printf "%s%s%s", added, changed, removed }'
}

# Exit 2 when the image carries no SBOM referrer, a stated case; 1 when oras
# could not tell, which is never taken for an absence.
fetch_sbom() {
    local image=$1 digest=$2 out=$3 ref referrers sbom_digest dir
    ref="${REGISTRY}/${image}@${digest}"
    referrers=$(oras discover --format json "$ref") || {
        err "oras discover failed on $ref"
        return 1
    }
    sbom_digest=$(jq -r --arg t "$SBOM_TYPE" '.referrers[]? | select(.artifactType == $t) | .digest' <<< "$referrers" | head -n1)
    [ -n "$sbom_digest" ] || {
        err "no SBOM referrer on $ref"
        return 2
    }
    dir=$(mktemp -d -p "$TMP")
    oras pull --output "$dir" "${REGISTRY}/${image}@${sbom_digest}" > /dev/null || {
        err "oras pull of the SBOM $sbom_digest of $ref failed"
        return 1
    }
    find "$dir" -name '*.json' -exec mv {} "$out" \; -quit
    [ -s "$out" ] || {
        err "SBOM referrer $sbom_digest of $ref pulled no json file"
        return 1
    }
}

inspect_labels() {
    skopeo inspect --retry-times 3 --no-tags "docker://$1" | jq -c '.Labels'
}

# A flavour the previous release lacked prints nothing and succeeds, so the
# notes can state it. Any other error fails: a transport problem must never
# read as "first release of this image".
previous_digest() {
    local image=$1 tag=$2 out status=0
    out=$(skopeo inspect --retry-times 3 --no-tags "docker://${REGISTRY}/${image}:${tag}" 2> "$TMP/prev-inspect.err") || status=$?
    if [ "$status" -ne 0 ]; then
        if absent_error "$(cat "$TMP/prev-inspect.err")"; then
            return 0
        fi
        cat "$TMP/prev-inspect.err" >&2
        err "cannot inspect the previous release ${image}:${tag}"
        return 1
    fi
    out=$(jq -r .Digest <<< "$out")
    [[ "$out" =~ ^sha256:[0-9a-f]{64}$ ]] || {
        err "no digest for ${image}:${tag}: '$out'"
        return 1
    }
    echo "$out"
}

# A previous revision missing from this history (a rewritten one) falls back
# to every commit of this tree, stated as such.
commits() {
    local prev=$1
    if [ -z "$prev" ]; then
        echo "_First release: every commit of this tree follows._"
        echo
        git log --no-merges --pretty="- \`%h\` %s" HEAD
    elif git cat-file -e "$prev^{commit}" 2> /dev/null; then
        git log --no-merges --pretty="- \`%h\` %s" "${prev}..HEAD"
    else
        echo "_Previous revision \`${prev:0:7}\` is not in this history: every commit of this tree follows._"
        echo
        git log --no-merges --pretty="- \`%h\` %s" HEAD
    fi
}

release() {
    local tag="" out="" files=() file releases prev
    while [ $# -gt 0 ]; do
        case "$1" in
            --release-tag)
                tag=$2
                shift 2
                ;;
            --out)
                out=$2
                shift 2
                ;;
            -*) fail "unknown option '$1'" ;;
            *)
                files+=("$1")
                shift
                ;;
        esac
    done
    [[ "$tag" =~ $TAG_SHAPE ]] || fail "--release-tag must be <fedora>.<yyyymmdd>[.N]: '$tag'"
    [ -n "$out" ] || fail "--out is required"
    local expected
    expected=$(wc -w <<< "$PACKAGES")
    [ "${#files[@]}" -eq "$expected" ] || fail "expected $expected env files (one per flavour), got ${#files[@]}"
    releases=$(gh release list --repo "$REPO" --limit 500 --json tagName,publishedAt,isDraft) || fail "gh release list failed"
    prev=$(previous_tag "$releases" "$tag")
    local base_version="" base_labels prev_revision="" prev_labels i
    local -a names digests bases base_digests kernels
    for file in "${files[@]}"; do
        read_env "$file" || exit 1
        base_labels=$(inspect_labels "${base_name}@${base_digest}") || fail "cannot inspect ${base_name}@${base_digest}"
        names+=("$image_name")
        digests+=("$digest")
        bases+=("$base_name")
        base_digests+=("$base_digest")
        kernels+=("$(jq -r '.["ostree.linux"] // "unknown"' <<< "$base_labels")")
        [ -n "$base_version" ] || base_version=$(jq -r '.["org.opencontainers.image.version"] // empty' <<< "$base_labels")
    done
    [ -n "$base_version" ] || fail "the base carries no version label"
    if [ -n "$prev" ]; then
        # The first flavour the previous release carried; none at all fails.
        local prev_ref="" pd
        for i in "${!names[@]}"; do
            pd=$(previous_digest "${names[$i]}" "$prev") || exit 1
            [ -z "$pd" ] || {
                prev_ref="${REGISTRY}/${names[$i]}@${pd}"
                break
            }
        done
        [ -n "$prev_ref" ] || fail "the previous release ${prev} carries none of: ${names[*]}"
        prev_labels=$(inspect_labels "$prev_ref") || fail "cannot inspect $prev_ref"
        prev_revision=$(jq -r '.["org.opencontainers.image.revision"] // empty' <<< "$prev_labels")
    fi
    {
        echo "Release \`${tag}\` of bazzite-mx, built from Bazzite \`${base_version}\` (\`stable\`)."
        if [ -n "$prev" ]; then
            echo "Previous release: [\`${prev}\`](https://github.com/${REPO}/releases/tag/${prev})."
        else
            echo "First release of this tree."
        fi
        echo
        echo "## Images"
        echo
        echo "| Image | Kernel | Digest |"
        echo "|---|---|---|"
        for i in "${!names[@]}"; do
            echo "| \`${REGISTRY}/${names[$i]}:${tag}\` | \`${kernels[$i]}\` | \`${digests[$i]}\` |"
        done
        echo
        local base_list=""
        for i in "${!bases[@]}"; do
            base_list+="${base_list:+, }\`${bases[$i]}@${base_digests[$i]}\`"
        done
        echo "Base images: ${base_list}."
        echo
        echo "## Packages"
        echo
        if [ -n "$prev" ]; then
            local curr_sbom prev_sbom curr_tsv prev_tsv prev_digest diff any=no why="" status
            for i in "${!names[@]}"; do
                curr_sbom=$TMP/curr-$i.json
                prev_sbom=$TMP/prev-$i.json
                curr_tsv=$TMP/curr-$i.tsv
                prev_tsv=$TMP/prev-$i.tsv
                status=0
                fetch_sbom "${names[$i]}" "${digests[$i]}" "$curr_sbom" || status=$?
                if [ "$status" -eq 2 ]; then
                    fail "the current ${names[$i]} has no SBOM: the build did not attach it"
                elif [ "$status" -ne 0 ]; then
                    fail "the SBOM of the current ${names[$i]} could not be read: see the error above"
                fi
                sbom_packages "$curr_sbom" "$curr_tsv" || exit 1
                # A transport error fails here and in fetch_sbom; the two
                # stated cases are a flavour the previous release lacked and
                # a missing referrer.
                prev_digest=$(previous_digest "${names[$i]}" "$prev") || exit 1
                if [ -z "$prev_digest" ]; then
                    echo "### ${names[$i]}: $(wc -l < "$curr_tsv") packages"
                    echo
                    echo "_First release of this image: \`${prev}\` did not carry it._"
                    why+="${why:+, }${names[$i]} not in ${prev}"
                else
                    status=0
                    fetch_sbom "${names[$i]}" "$prev_digest" "$prev_sbom" 2> "$TMP/prev-sbom.err" || status=$?
                    if [ "$status" -eq 0 ] && sbom_packages "$prev_sbom" "$prev_tsv" 2> /dev/null; then
                        diff=$(package_diff "$prev_tsv" "$curr_tsv")
                        echo "### ${names[$i]}: $(wc -l < "$curr_tsv") packages, since \`${prev}\`"
                        echo
                        if [ -n "$diff" ]; then
                            echo "$diff"
                        else
                            echo "_No package changed._"
                        fi
                        any=yes
                    elif [ "$status" -eq 1 ]; then
                        fail "the SBOM of the previous ${names[$i]} (${prev}) could not be read: $(cat "$TMP/prev-sbom.err")"
                    else
                        echo "### ${names[$i]}: $(wc -l < "$curr_tsv") packages"
                        echo
                        echo "_No package diff: the previous release \`${prev}\` carries no SBOM._"
                        why+="${why:+, }${names[$i]}:${prev} without SBOM"
                    fi
                fi
                echo
            done
            [ "$any" = yes ] || echo "changelog: no package diff for ${tag}: ${why}" >&2
        else
            echo "_No previous release to compare with._"
            echo
        fi
        echo "## Commits"
        echo
        commits "$prev_revision"
        echo
        echo "## Switch a host"
        echo
        echo "A stock Bazzite host carries no trust for \`${REGISTRY}\`: the first rebase goes through the unsigned"
        echo "transport and the recipe in the image moves it to the signed one ([docs/migration.md](https://github.com/${REPO}/blob/main/docs/migration.md))."
        echo
        echo '```bash'
        echo "sudo rpm-ostree rebase ostree-unverified-registry:${REGISTRY}/<image>:stable"
        echo "systemctl reboot"
        echo "ujust migrate apply"
        echo "ujust verify-host"
        echo '```'
        echo
        echo "A migrated host follows \`:stable\`; to pin this release instead:"
        echo
        echo '```bash'
        echo "sudo bootc switch --enforce-container-sigpolicy ${REGISTRY}/<image>:${tag}"
        echo '```'
        echo
        echo "\`<image>\` is \`bazzite-mx\` (AMD, Intel), \`bazzite-mx-nvidia-open\` (NVIDIA, open kernel modules) or"
        echo "\`bazzite-mx-nvidia\` (NVIDIA, closed driver). Every image is signed with the"
        echo "repository's [\`cosign.pub\`](https://github.com/${REPO}/blob/main/cosign.pub) and its build is attested"
        echo "(\`gh attestation verify oci://${REGISTRY}/<image>@<digest> --repo ${REPO}\`)."
        echo
        echo "Dated tags stay on GHCR for 90 days (the 7 newest are kept beyond that); this release page outlives its tag."
    } > "$out"
    echo "${tag}: Stable (Bazzite ${base_version})"
}

self_test() {
    local dir n=0 releases out
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    releases='[{"tagName":"44.20260902","publishedAt":"2026-09-02T08:01:52Z","isDraft":false},
        {"tagName":"testing-44.20260902","publishedAt":"2026-09-02T08:01:53Z","isDraft":false},
        {"tagName":"44.20260901","publishedAt":"2026-09-01T08:00:00Z","isDraft":false},
        {"tagName":"44.20260910","publishedAt":"2026-09-10T08:00:00Z","isDraft":true},
        {"tagName":"44.20260903","publishedAt":"2026-09-03T08:00:00Z","isDraft":false}]'
    [ "$(previous_tag "$releases" 44.20260903)" = 44.20260902 ] || fail "self-test: previous tag not the newest stable release"
    [ "$(previous_tag "$releases" 44.20260904)" = 44.20260903 ] || fail "self-test: current tag not excluded"
    [ -z "$(previous_tag '[]' 44.20260903)" ] || fail "self-test: empty release list gave a tag"
    cat > "$dir/prev.json" << 'EOF'
{"artifacts":[{"type":"rpm","name":"kernel","version":"7.2.1-ogc4.1.fc44"},{"type":"rpm","name":"old","version":"1-1.fc44"},
{"type":"rpm","name":"same","version":"2-1.fc44"},{"type":"python","name":"pip","version":"25.0"}]}
EOF
    cat > "$dir/curr.json" << 'EOF'
{"artifacts":[{"type":"rpm","name":"kernel","version":"7.2.2-ogc1.fc44"},{"type":"rpm","name":"new","version":"3-1.fc44"},
{"type":"rpm","name":"same","version":"2-1.fc44"},{"type":"python","name":"pip","version":"26.0"}]}
EOF
    sbom_packages "$dir/prev.json" "$dir/prev.tsv" || fail "self-test: SBOM not parsed"
    sbom_packages "$dir/curr.json" "$dir/curr.tsv" || fail "self-test: SBOM not parsed"
    [ "$(wc -l < "$dir/curr.tsv")" -eq 3 ] || fail "self-test: expected 3 RPMs, got $(wc -l < "$dir/curr.tsv")"
    local diff
    diff=$(package_diff "$dir/prev.tsv" "$dir/curr.tsv")
    grep -qx -- '- \*\*new\*\* 3-1.fc44 (added)' <<< "$diff" || fail "self-test: added package missing: $diff"
    grep -qx -- '- \*\*kernel\*\* 7.2.1-ogc4.1.fc44 → 7.2.2-ogc1.fc44' <<< "$diff" || fail "self-test: changed package missing"
    grep -qx -- '- \*\*old\*\* 1-1.fc44 (removed)' <<< "$diff" || fail "self-test: removed package missing"
    grep -q 'same' <<< "$diff" && fail "self-test: unchanged package listed"
    [ -z "$(package_diff "$dir/curr.tsv" "$dir/curr.tsv")" ] || fail "self-test: identical SBOMs gave a diff"
    echo '{"artifacts":[{"type":"python","name":"pip","version":"26.0"}]}' > "$dir/norpm.json"
    n=$((n + 1))
    if sbom_packages "$dir/norpm.json" "$dir/norpm.tsv" 2> /dev/null; then
        fail "self-test: SBOM without RPMs accepted"
    fi
    printf 'image_name=bazzite-mx\ndigest=sha256:short\nbase_name=ghcr.io/ublue-os/bazzite\nbase_digest=sha256:%064d\n' 0 > "$dir/bad.env"
    n=$((n + 1))
    if read_env "$dir/bad.env" 2> /dev/null; then
        fail "self-test: env file with a short digest accepted"
    fi
    n=$((n + 1))
    if out=$(release --release-tag 44.20260903 --out "$dir/notes.md" "$dir/bad.env" "$dir/bad.env" 2>&1); then
        fail "self-test: two env files accepted for $(wc -w <<< "$PACKAGES") flavours"
    fi
    grep -q "expected $(wc -w <<< "$PACKAGES") env files" <<< "$out" || fail "self-test: the env-file count is not PACKAGES': $out"
    # A skopeo shim on PATH drives the three previous_digest outcomes.
    mkdir -p "$dir/bin"
    cat > "$dir/bin/skopeo" << 'EOF'
#!/usr/bin/env bash
[[ "${!#}" == docker://ghcr.io/matrixdj96/bazzite-mx*:44.20260903 ]] || { echo "shim: unexpected reference ${!#}" >&2; exit 3; }
case "$SKOPEO_SHIM" in
    ok) printf '{"Digest":"sha256:%064d"}\n' 7 ;;
    absent) echo 'time="x" level=fatal msg="Error parsing image name \"docker://ghcr.io/x/y:t\": reading manifest t in ghcr.io/x/y: manifest unknown"' >&2; exit 1 ;;
    *) echo 'unauthorized: authentication required' >&2; exit 1 ;;
esac
EOF
    chmod +x "$dir/bin/skopeo"
    local d
    d=$(PATH="$dir/bin:$PATH" SKOPEO_SHIM=ok previous_digest bazzite-mx 44.20260903) || fail "self-test: a readable previous image refused"
    [ "$d" = "sha256:$(printf '%064d' 7)" ] || fail "self-test: previous digest not read: '$d'"
    d=$(PATH="$dir/bin:$PATH" SKOPEO_SHIM=absent previous_digest bazzite-mx-nvidia 44.20260903) || fail "self-test: a flavour absent from the previous release failed instead of being stated"
    [ -z "$d" ] || fail "self-test: an absent previous image gave a digest: '$d'"
    n=$((n + 1))
    if PATH="$dir/bin:$PATH" SKOPEO_SHIM=auth previous_digest bazzite-mx 44.20260903 > /dev/null 2>&1; then
        fail "self-test: a transport error on the previous image taken for an absent one"
    fi
    # An oras shim drives fetch_sbom: no referrer is stated (exit 2), a
    # transport error is a failure (exit 1), never "no SBOM".
    cat > "$dir/bin/oras" << 'EOF'
#!/usr/bin/env bash
case "$ORAS_SHIM" in
    none) echo '{"referrers":[]}' ;;
    *) echo 'Error: failed to resolve ghcr.io: dial tcp: lookup ghcr.io: no such host' >&2; exit 1 ;;
esac
EOF
    chmod +x "$dir/bin/oras"
    local status
    status=0
    PATH="$dir/bin:$PATH" ORAS_SHIM=none fetch_sbom bazzite-mx "sha256:$(printf '%064d' 7)" "$dir/none.json" 2> /dev/null || status=$?
    [ "$status" -eq 2 ] || fail "self-test: an image without an SBOM referrer exited $status, not 2"
    n=$((n + 1))
    status=0
    PATH="$dir/bin:$PATH" ORAS_SHIM=down fetch_sbom bazzite-mx "sha256:$(printf '%064d' 7)" "$dir/down.json" 2> /dev/null || status=$?
    [ "$status" -eq 1 ] || fail "self-test: a transport error on oras discover exited $status, not 1 (taken for no SBOM)"
    echo "self-test ok: previous tag picked 3 ways, 1 SBOM diff right, previous digest classified 3 ways, SBOM absence told from a transport error, $n bad inputs refused"
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
case "${1:-}" in
    --self-test) self_test ;;
    release)
        shift
        release "$@"
        ;;
    *) fail "usage: changelog.sh release --release-tag <tag> --out <file> <env-file>... | --self-test" ;;
esac
