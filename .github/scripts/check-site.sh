#!/usr/bin/env bash
# The check of the site, run by the lint job and by deploy-pages.yml before the
# upload, so a page that drifted from the images, points at a file the site
# does not ship or does not parse never reaches Pages.
#
#   check-site.sh <dir> [--offline]
#       dir: the directory upload-pages-artifact packages (site/)
#       --offline: skip the fetch of the external links
#   check-site.sh --self-test
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

KEY_URL=https://raw.githubusercontent.com/MatrixDJ96/bazzite-mx/main/cosign.pub
# The release run publishes neither a testing stream nor the :latest alias.
FORBIDDEN=':testing|:latest'
REPO_LINK='^https://(github\.com/MatrixDJ96/bazzite-mx/blob/main|raw\.githubusercontent\.com/MatrixDJ96/bazzite-mx/main)/'
# The checkout the repository links resolve in; the self-test points it at a fixture.
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}

# Pages refuses an artefact whose tar carries links (GitHub docs, "Using custom
# workflows with GitHub Pages").
check_tree() {
    local dir=$1 links
    [ -d "$dir" ] || {
        err "$dir is not a directory"
        return 1
    }
    [ -f "$dir/index.html" ] || {
        err "$dir/index.html missing"
        return 1
    }
    links=$(find "$dir" -type l -o -type f -links +1)
    [ -z "$links" ] || {
        err "links in $dir (Pages refuses them):"$'\n'"$links"
        return 1
    }
    echo "tree ok: index.html present, no links"
}

pages_of() {
    (cd "$1" && ls ./*.html) | sed 's|^\./||' | LC_ALL=C sort
}

# The pages are written as XML, so every unclosed or misnested tag is a parse
# error to expat, which both runners carry.
check_wellformed() {
    local page=$1 out
    out=$(python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$page" 2>&1) || {
        err "$page is not well-formed: ${out##*$'\n'}"
        return 1
    }
    echo "markup ok: $(basename "$page") well-formed"
}

check_forbidden() {
    local page=$1 bad
    bad=$(grep -nE "$FORBIDDEN" "$page" || true)
    [ -z "$bad" ] || {
        err "$page offers what the release run does not publish:"$'\n'"$bad"
        return 1
    }
    echo "forbidden ok: $(basename "$page") offers nothing the release run does not publish"
}

# Anchored: bazzite-mx and bazzite-mx-nvidia are prefixes of the other images,
# so a page must name each one whole.
check_images() {
    local page=$1 image
    for image in $PACKAGES; do
        grep -qE "$REGISTRY/$image([^A-Za-z0-9-]|$)" "$page" || {
            err "$page does not name $REGISTRY/$image"
            return 1
        }
    done
    echo "images ok: $(basename "$page") names the $(wc -w <<< "$PACKAGES") images"
}

check_key() {
    local page=$1
    grep -qF "$KEY_URL" "$page" || {
        err "$page does not name the public key $KEY_URL"
        return 1
    }
    echo "key ok: $(basename "$page") names the public key"
}

# Every local reference has to name a file of the directory; plain http is
# refused; no src and no <link> href may point outside the site.
check_local() {
    local dir=$1 page=$2 m attr ref path n=0 link_hrefs
    link_hrefs=$(grep -oE '<link[^>]*href="[^"]+"' "$page" | grep -oE 'href="[^"]+"$' || true)
    while IFS= read -r m; do
        attr=${m%%=*}
        ref=${m#*=\"}
        ref=${ref%\"}
        case "$ref" in
            https://*)
                if [ "$attr" = src ] || grep -qF -- "$m" <<< "$link_hrefs"; then
                    err "$page: external asset $ref"
                    return 1
                fi
                continue
                ;;
            http://*)
                err "$page: plain http link $ref"
                return 1
                ;;
            '#'* | data:* | mailto:*) continue ;;
        esac
        path=${ref%%#*}
        path=${path%%\?*}
        [ -f "$dir/$path" ] || {
            err "$page: $attr=\"$ref\" is not a file of $dir"
            return 1
        }
        n=$((n + 1))
    done < <(grep -oE '(href|src)="[^"]+"' "$page" | sort -u)
    echo "local ok: $(basename "$page"), $n references resolve in the site"
}

# A stylesheet pulls nothing from outside: no url() and no @import naming a
# scheme or a host.
check_css() {
    local css=$1 bad
    bad=$(grep -nE 'url\([^)]*(https?:|//)|@import[^;]*(https?:|//)' "$css" || true)
    [ -z "$bad" ] || {
        err "$css pulls from outside the site:"$'\n'"$bad"
        return 1
    }
    echo "css ok: $(basename "$css") pulls nothing from outside"
}

# Exit 2 when the page has no <nav> or more than one, 1 when it does not parse.
nav_hrefs() {
    python3 - "$1" << 'EOF'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
navs = [n for n in root.iter() if n.tag.split('}')[-1] == 'nav']
if len(navs) != 1:
    sys.exit(2)
print('\n'.join(sorted((a.get('href', '').split('#')[0] for a in navs[0].iter() if a.tag.split('}')[-1] == 'a'), key=lambda h: h.encode())))
EOF
}

# The nav hrefs must be exactly the pages of the directory, so no page is
# orphaned and no entry is stale.
check_nav() {
    local dir=$1 pages page navs
    pages=$(pages_of "$dir")
    for page in $pages; do
        navs=$(nav_hrefs "$dir/$page") || {
            [ $? -eq 2 ] && err "$dir/$page: no single <nav>" || err "$dir/$page: not parsed"
            return 1
        }
        [ "$navs" = "$pages" ] || {
            err "$dir/$page: nav lists [$(tr '\n' ' ' <<< "$navs")] but the site has [$(tr '\n' ' ' <<< "$pages")]"
            return 1
        }
    done
    echo "nav ok: $(wc -w <<< "$pages") pages, each reachable from every page"
}

# A link into this repository is resolved against the checkout, so a page and
# the file it points at ship together and the check holds before main. Every
# other https href is fetched once, across all the pages.
check_links() {
    local url path n=0 local_n=0
    while IFS= read -r url; do
        if [[ "$url" =~ $REPO_LINK ]]; then
            path=${url#"${BASH_REMATCH[0]}"}
            [ -f "$REPO_ROOT/$path" ] || {
                err "dead link: $url ($path is not in the checkout)"
                return 1
            }
            local_n=$((local_n + 1))
        else
            curl -fsSL --proto '=https' --max-time 30 -o /dev/null "$url" || {
                err "dead link: $url"
                return 1
            }
        fi
        n=$((n + 1))
    done < <(grep -ohE 'href="https://[^"]+"' "$@" | sed 's/^href="//; s/"$//' | sort -u)
    [ "$n" -gt 0 ] || {
        err "no https link on $*"
        return 1
    }
    echo "links ok: $n answered ($local_n in the checkout)"
}

check_site() {
    local dir=$1 offline=$2 page pages=()
    check_tree "$dir" || exit 1
    for page in $(pages_of "$dir"); do
        check_wellformed "$dir/$page" || exit 1
        check_forbidden "$dir/$page" || exit 1
        check_local "$dir" "$dir/$page" || exit 1
        pages+=("$dir/$page")
    done
    for page in "$dir"/*.css; do
        [ -e "$page" ] || continue
        check_css "$page" || exit 1
    done
    check_nav "$dir" || exit 1
    for page in index.html images.html; do
        [ ! -f "$dir/$page" ] || check_images "$dir/$page" || exit 1
    done
    for page in index.html verify.html; do
        [ ! -f "$dir/$page" ] || check_key "$dir/$page" || exit 1
    done
    if [ "$offline" = true ]; then
        echo "links skipped: --offline"
    else
        check_links "${pages[@]}" || exit 1
    fi
    echo "check-site ok: $dir, ${#pages[@]} pages"
}

self_test() {
    local dir good
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    good=$dir/good
    mkdir -p "$good"
    # A two-page site with everything the checks want.
    : > "$good/style.css"
    cat > "$good/index.html" << EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8" /><title>t</title><link rel="stylesheet" href="style.css" /></head>
<body><nav><a href="index.html">home</a><a href="images.html">images</a></nav>
<p><a href="https://127.0.0.1:9/">x</a> <a href="#top">top</a> $REGISTRY/bazzite-mx $REGISTRY/bazzite-mx-nvidia-open $REGISTRY/bazzite-mx-nvidia $KEY_URL</p></body></html>
EOF
    cat > "$good/images.html" << EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8" /><title>i</title><link rel="stylesheet" href="style.css" /></head>
<body><nav><a href="index.html">home</a><a href="images.html">images</a></nav>
<p>$REGISTRY/bazzite-mx $REGISTRY/bazzite-mx-nvidia-open $REGISTRY/bazzite-mx-nvidia</p></body></html>
EOF
    check_site "$good" true > /dev/null || fail "self-test: a good site refused"
    # A missing check fails every input alike, so each one must be shown to
    # accept the good site before its refusals count.
    check_wellformed "$good/index.html" > /dev/null || fail "self-test: check_wellformed refused the good site"
    [ "$(check_forbidden "$good/index.html")" = "forbidden ok: index.html offers nothing the release run does not publish" ] \
        || fail "self-test: check_forbidden passed the good site without saying so"
    check_images "$good/index.html" > /dev/null || fail "self-test: check_images refused the good site"
    check_key "$good/index.html" > /dev/null || fail "self-test: check_key refused the good site"
    check_local "$good" "$good/index.html" > /dev/null || fail "self-test: check_local refused the good site"
    check_css "$good/style.css" > /dev/null || fail "self-test: check_css refused the good stylesheet"
    check_nav "$good" > /dev/null || fail "self-test: check_nav refused the good site"
    # One lesion each. Port 9 on loopback is refused at once, no network needed.
    local n=0
    mkdir -p "$dir/link"
    cp "$good/index.html" "$dir/link/"
    ln -s index.html "$dir/link/home.html"
    if check_tree "$dir/link" > /dev/null 2>&1; then
        fail "self-test: a symlink accepted"
    fi
    n=$((n + 1))
    mkdir -p "$dir/torn"
    sed 's|</p>||' "$good/index.html" > "$dir/torn/index.html"
    if check_wellformed "$dir/torn/index.html" > /dev/null 2>&1; then
        fail "self-test: an unclosed tag accepted"
    fi
    n=$((n + 1))
    mkdir -p "$dir/stale"
    sed 's|bazzite-mx-nvidia-open|bazzite-mx-nvidia-open bazzite-mx:testing|' "$good/index.html" > "$dir/stale/index.html"
    if check_forbidden "$dir/stale/index.html" > /dev/null 2>&1; then
        fail "self-test: a :testing reference accepted"
    fi
    n=$((n + 1))
    mkdir -p "$dir/short"
    sed "s|$REGISTRY/bazzite-mx-nvidia-open||" "$good/index.html" > "$dir/short/index.html"
    if check_images "$dir/short/index.html" > /dev/null 2>&1; then
        fail "self-test: a page missing an image accepted"
    fi
    n=$((n + 1))
    mkdir -p "$dir/nokey"
    sed "s|$KEY_URL||" "$good/index.html" > "$dir/nokey/index.html"
    if check_key "$dir/nokey/index.html" > /dev/null 2>&1; then
        fail "self-test: a page missing the public key accepted"
    fi
    n=$((n + 1))
    # bazzite-mx-nvidia inside bazzite-mx-nvidia-open does not name it.
    mkdir -p "$dir/prefix"
    sed "s| $REGISTRY/bazzite-mx-nvidia | |" "$good/index.html" > "$dir/prefix/index.html"
    if check_images "$dir/prefix/index.html" > /dev/null 2>&1; then
        fail "self-test: a page naming an image only as a prefix of another accepted"
    fi
    n=$((n + 1))
    if check_links "$good/index.html" > /dev/null 2>&1; then
        fail "self-test: a dead link accepted"
    fi
    n=$((n + 1))
    # A repository link is never fetched: the fixture root has no network.
    mkdir -p "$dir/repo/docs" "$dir/repolink"
    : > "$dir/repo/docs/present.md"
    sed 's|https://127.0.0.1:9/|https://github.com/MatrixDJ96/bazzite-mx/blob/main/docs/present.md|' \
        "$good/index.html" > "$dir/repolink/index.html"
    REPO_ROOT=$dir/repo check_links "$dir/repolink/index.html" > /dev/null || fail "self-test: a repository link to a present file refused"
    sed -i 's|docs/present.md|docs/absent.md|' "$dir/repolink/index.html"
    if REPO_ROOT=$dir/repo check_links "$dir/repolink/index.html" > /dev/null 2>&1; then
        fail "self-test: a repository link to an absent file accepted"
    fi
    n=$((n + 1))
    mkdir -p "$dir/absent"
    cp "$good"/* "$dir/absent/"
    sed -i 's|href="#top"|href="absent.html"|' "$dir/absent/index.html"
    if check_local "$dir/absent" "$dir/absent/index.html" > /dev/null 2>&1; then
        fail "self-test: a link to a file the site does not ship accepted"
    fi
    n=$((n + 1))
    mkdir -p "$dir/asset"
    cp "$good"/* "$dir/asset/"
    sed -i 's|</head>|<script src="https://127.0.0.1:9/x.js"></script></head>|' "$dir/asset/index.html"
    if check_local "$dir/asset" "$dir/asset/index.html" > /dev/null 2>&1; then
        fail "self-test: an external asset accepted"
    fi
    n=$((n + 1))
    mkdir -p "$dir/linkhref"
    cp "$good"/* "$dir/linkhref/"
    sed -i 's|href="style.css"|href="https://127.0.0.1:9/x.css"|' "$dir/linkhref/index.html"
    if check_local "$dir/linkhref" "$dir/linkhref/index.html" > /dev/null 2>&1; then
        fail "self-test: a stylesheet fetched from outside the site accepted"
    fi
    n=$((n + 1))
    mkdir -p "$dir/css"
    cp "$good"/* "$dir/css/"
    printf 'body { background: url(https://127.0.0.1:9/bg.png); }\n' > "$dir/css/style.css"
    if check_css "$dir/css/style.css" > /dev/null 2>&1; then
        fail "self-test: a stylesheet pulling from outside the site accepted"
    fi
    n=$((n + 1))
    printf '@import "https://127.0.0.1:9/x.css";\n' > "$dir/css/style.css"
    if check_css "$dir/css/style.css" > /dev/null 2>&1; then
        fail "self-test: a stylesheet importing from outside the site accepted"
    fi
    n=$((n + 1))
    mkdir -p "$dir/http"
    cp "$good"/* "$dir/http/"
    sed -i 's|https://127.0.0.1:9/|http://127.0.0.1:9/|' "$dir/http/index.html"
    if check_local "$dir/http" "$dir/http/index.html" > /dev/null 2>&1; then
        fail "self-test: a plain http link accepted"
    fi
    n=$((n + 1))
    mkdir -p "$dir/orphan"
    cp "$good"/* "$dir/orphan/"
    cp "$good/images.html" "$dir/orphan/orphan.html"
    if check_nav "$dir/orphan" > /dev/null 2>&1; then
        fail "self-test: a page no nav reaches accepted"
    fi
    n=$((n + 1))
    echo "self-test ok: 1 good site accepted, $n bad inputs refused"
}

case "${1:-}" in
    --self-test) self_test ;;
    "" | -*) fail "usage: check-site.sh <dir> [--offline] | --self-test" ;;
    *)
        offline=false
        [ "${2:-}" != "--offline" ] || offline=true
        check_site "$1" "$offline"
        ;;
esac
