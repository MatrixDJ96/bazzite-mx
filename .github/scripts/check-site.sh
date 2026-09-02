#!/usr/bin/env bash
# The check of the site, run by the lint job and by deploy-pages.yml before
# the upload, so a page that drifted from the images, points at a file the
# site does not ship or does not parse never reaches Pages. Page by page: the
# markup parses, nothing the release run does not publish is offered, every
# local reference is a file of the site, no asset comes from outside; then
# the stylesheets, the nav of every page, the images and the public key on
# the front pages, and every https link once.
#
# Usage: check-site.sh <dir> [--offline]
#          <dir>       the directory upload-pages-artifact packages (site/)
#          --offline   skip the fetch of the external links
#        check-site.sh --self-test
# Output: one `<check> ok: …` line per check that passed, then
#   `check-site ok: <dir>, N pages`; the first failure is one `check-site: …`
#   line on stderr.
# Exit status: 0 the site passes every check; 1 on the first check failed or
#   a bad argument.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

KEY_URL=https://raw.githubusercontent.com/MatrixDJ96/bazzite-mx/main/cosign.pub

# The release run publishes neither a testing stream nor the :latest alias.
FORBIDDEN=':testing|:latest'

# A link into this repository, resolved on the checkout instead of fetched.
REPO_LINK='^https://(github\.com/MatrixDJ96/bazzite-mx/blob/main'
REPO_LINK+='|raw\.githubusercontent\.com/MatrixDJ96/bazzite-mx/main)/'

# The checkout the repository links resolve in; the self-test points it at a
# fixture.
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}

# --- the tree -----------------------------------------------------------------

# check_tree <dir>: a directory with an index.html and no link. Pages
# refuses an artefact whose tar carries links (GitHub docs, "Using custom
# workflows with GitHub Pages").
check_tree() {
    local dir=$1
    local links

    if [ ! -d "$dir" ]; then
        print_error "$dir is not a directory"
        return 1
    fi
    if [ ! -f "$dir/index.html" ]; then
        print_error "$dir/index.html missing"
        return 1
    fi

    links=$(find "$dir" -type l -o -type f -links +1)
    if [ -n "$links" ]; then
        print_error "links in $dir (Pages refuses them):"$'\n'"$links"
        return 1
    fi

    echo "tree ok: index.html present, no links"
}

# pages_of <dir>: the html files of the directory, one per line, in byte
# order (the order nav_hrefs prints).
pages_of() {
    local dir=$1

    find "$dir" -maxdepth 1 -name '*.html' -printf '%f\n' | LC_ALL=C sort
}

# --- one page -----------------------------------------------------------------

# check_wellformed <page>: the page parses as XML. The pages are written as
# XML, so every unclosed or misnested tag is a parse error to expat, which
# both runners carry.
check_wellformed() {
    local page=$1
    local parse_output

    if ! parse_output=$(python3 -c \
        'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$page" 2>&1); then
        print_error "$page is not well-formed: ${parse_output##*$'\n'}"
        return 1
    fi

    echo "markup ok: $(basename "$page") well-formed"
}

# check_forbidden <page>: no reference to a tag the release run does not
# publish.
check_forbidden() {
    local page=$1
    local offending_lines

    offending_lines=$(grep -nE "$FORBIDDEN" "$page" || true)
    if [ -n "$offending_lines" ]; then
        print_error "$page offers what the release run does not publish:"$'\n'"$offending_lines"
        return 1
    fi

    echo "forbidden ok: $(basename "$page") offers nothing the release run does not publish"
}

# check_images <page>: every image named whole. The match is anchored:
# bazzite-mx and bazzite-mx-nvidia are prefixes of the other images.
check_images() {
    local page=$1
    local image

    for image in $PACKAGES; do
        if ! grep -qE "$REGISTRY/$image([^A-Za-z0-9-]|$)" "$page"; then
            print_error "$page does not name $REGISTRY/$image"
            return 1
        fi
    done

    echo "images ok: $(basename "$page") names the $(wc -w <<< "$PACKAGES") images"
}

# check_key <page>: the public key named by its URL.
check_key() {
    local page=$1

    if ! grep -qF "$KEY_URL" "$page"; then
        print_error "$page does not name the public key $KEY_URL"
        return 1
    fi

    echo "key ok: $(basename "$page") names the public key"
}

# check_local <dir> <page>: every href and src of the page. A local
# reference names a file of the directory; plain http is refused; an https
# src, and the https href of a <link>, would pull an asset from outside the
# site and are refused too.
check_local() {
    local dir=$1
    local page=$2
    local match attribute reference path link_hrefs
    local resolved=0

    link_hrefs=$(grep -oE '<link[^>]*href="[^"]+"' "$page" | grep -oE 'href="[^"]+"$' || true)

    while IFS= read -r match; do
        attribute=${match%%=*}
        reference=${match#*=\"}
        reference=${reference%\"}

        case "$reference" in
            https://*)
                if [ "$attribute" = src ] || grep -qF -- "$match" <<< "$link_hrefs"; then
                    print_error "$page: external asset $reference"
                    return 1
                fi
                continue
                ;;
            http://*)
                print_error "$page: plain http link $reference"
                return 1
                ;;
            '#'* | data:* | mailto:*)
                continue
                ;;
        esac

        path=${reference%%#*}
        path=${path%%\?*}
        if [ ! -f "$dir/$path" ]; then
            print_error "$page: $attribute=\"$reference\" is not a file of $dir"
            return 1
        fi
        resolved=$((resolved + 1))
    done < <(grep -oE '(href|src)="[^"]+"' "$page" | sort -u)

    echo "local ok: $(basename "$page"), $resolved references resolve in the site"
}

# check_css <stylesheet>: no url() and no @import naming a scheme or a host.
check_css() {
    local stylesheet=$1
    local from_outside='url\([^)]*(https?:|//)|@import[^;]*(https?:|//)'
    local offending_lines

    offending_lines=$(grep -nE "$from_outside" "$stylesheet" || true)
    if [ -n "$offending_lines" ]; then
        print_error "$stylesheet pulls from outside the site:"$'\n'"$offending_lines"
        return 1
    fi

    echo "css ok: $(basename "$stylesheet") pulls nothing from outside"
}

# --- the site -----------------------------------------------------------------

# nav_hrefs <page>: the hrefs of the page's <nav>, fragments dropped, one per
# line in byte order. Status 2 when the page has no <nav> or more than one,
# 1 when it does not parse.
nav_hrefs() {
    local page=$1

    python3 - "$page" << 'EOF'
import sys, xml.etree.ElementTree as ET


def local_name(element):
    return element.tag.split('}')[-1]


root = ET.parse(sys.argv[1]).getroot()
navs = [element for element in root.iter() if local_name(element) == 'nav']
if len(navs) != 1:
    sys.exit(2)
hrefs = [a.get('href', '').split('#')[0] for a in navs[0].iter() if local_name(a) == 'a']
print('\n'.join(sorted(hrefs, key=lambda href: href.encode())))
EOF
}

# check_nav <dir>: the nav of every page lists exactly the pages of the
# directory, so no page is orphaned and no entry is stale.
check_nav() {
    local dir=$1
    local pages page navs status

    pages=$(pages_of "$dir")
    for page in $pages; do
        if navs=$(nav_hrefs "$dir/$page"); then
            status=0
        else
            status=$?
        fi
        if [ "$status" -eq 2 ]; then
            print_error "$dir/$page: no single <nav>"
            return 1
        fi
        if [ "$status" -ne 0 ]; then
            print_error "$dir/$page: not parsed"
            return 1
        fi

        if [ "$navs" != "$pages" ]; then
            print_error "$dir/$page: nav lists [$(tr '\n' ' ' <<< "$navs")]" \
                "but the site has [$(tr '\n' ' ' <<< "$pages")]"
            return 1
        fi
    done

    echo "nav ok: $(wc -w <<< "$pages") pages, each reachable from every page"
}

# check_links <page>...: every https href of the pages, each fetched once. A
# link into this repository is resolved against the checkout instead, so a
# page and the file it points at ship together and the check holds before
# the file is on main.
check_links() {
    local url path
    local answered=0
    local in_checkout=0

    while IFS= read -r url; do
        if [[ "$url" =~ $REPO_LINK ]]; then
            path=${url#"${BASH_REMATCH[0]}"}
            if [ ! -f "$REPO_ROOT/$path" ]; then
                print_error "dead link: $url ($path is not in the checkout)"
                return 1
            fi
            in_checkout=$((in_checkout + 1))
        elif ! curl -fsSL --proto '=https' --max-time 30 -o /dev/null "$url"; then
            print_error "dead link: $url"
            return 1
        fi
        answered=$((answered + 1))
    done < <(grep -ohE 'href="https://[^"]+"' "$@" | sed 's/^href="//; s/"$//' | sort -u)

    if [ "$answered" -eq 0 ]; then
        print_error "no https link on $*"
        return 1
    fi

    echo "links ok: $answered answered ($in_checkout in the checkout)"
}

# check_page <dir> <page>: the three checks of one page, the script stopping
# at the first that fails.
check_page() {
    local dir=$1
    local page=$2

    if ! check_wellformed "$dir/$page"; then
        exit 1
    fi
    if ! check_forbidden "$dir/$page"; then
        exit 1
    fi
    if ! check_local "$dir" "$dir/$page"; then
        exit 1
    fi
}

check_stylesheets() {
    local dir=$1
    local stylesheet

    for stylesheet in "$dir"/*.css; do
        if [ ! -e "$stylesheet" ]; then
            continue
        fi
        if ! check_css "$stylesheet"; then
            exit 1
        fi
    done
}

# check_front_pages <dir>: the images on the home and the images page, the
# public key on the home and the verify page, each when the site ships it.
check_front_pages() {
    local dir=$1
    local page

    for page in index.html images.html; do
        if [ -f "$dir/$page" ] && ! check_images "$dir/$page"; then
            exit 1
        fi
    done

    for page in index.html verify.html; do
        if [ -f "$dir/$page" ] && ! check_key "$dir/$page"; then
            exit 1
        fi
    done
}

# check_site <dir> <offline>: every check in order, the links last and only
# when offline is not `true`.
check_site() {
    local dir=$1
    local offline=$2
    local page
    local pages=()

    if ! check_tree "$dir"; then
        exit 1
    fi

    for page in $(pages_of "$dir"); do
        check_page "$dir" "$page"
        pages+=("$dir/$page")
    done
    check_stylesheets "$dir"

    if ! check_nav "$dir"; then
        exit 1
    fi
    check_front_pages "$dir"

    if [ "$offline" = true ]; then
        echo "links skipped: --offline"
    elif ! check_links "${pages[@]}"; then
        exit 1
    fi

    echo "check-site ok: $dir, ${#pages[@]} pages"
}

# --- self-test ----------------------------------------------------------------
#
# A two-page site with everything the checks want, then one lesion per
# check. The external link goes to port 9 on loopback, refused at once with
# no network; a repository link is resolved on a fixture checkout.

# self_test_write_good_site <dir>: index.html, images.html and an empty
# stylesheet.
self_test_write_good_site() {
    local dir=$1

    mkdir -p "$dir"
    : > "$dir/style.css"
    cat > "$dir/index.html" << EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8" /><title>t</title>
<link rel="stylesheet" href="style.css" /></head>
<body><nav><a href="index.html">home</a><a href="images.html">images</a></nav>
<p><a href="https://127.0.0.1:9/">x</a> <a href="#top">top</a>
$REGISTRY/bazzite-mx $REGISTRY/bazzite-mx-nvidia-open $REGISTRY/bazzite-mx-nvidia $KEY_URL</p>
</body></html>
EOF
    cat > "$dir/images.html" << EOF
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8" /><title>i</title>
<link rel="stylesheet" href="style.css" /></head>
<body><nav><a href="index.html">home</a><a href="images.html">images</a></nav>
<p>$REGISTRY/bazzite-mx $REGISTRY/bazzite-mx-nvidia-open $REGISTRY/bazzite-mx-nvidia</p>
</body></html>
EOF
}

# self_test_good_site_accepted <good>: the whole site offline, then each
# check on its own. A missing check fails every input alike, so each one
# must be shown to accept the good site before its refusals count.
self_test_good_site_accepted() {
    local good=$1
    local forbidden_line="forbidden ok: index.html offers nothing the release run does not publish"

    if ! check_site "$good" true > /dev/null; then
        fail_self_test "a good site refused"
    fi

    if ! check_wellformed "$good/index.html" > /dev/null; then
        fail_self_test "check_wellformed refused the good site"
    fi
    if [ "$(check_forbidden "$good/index.html")" != "$forbidden_line" ]; then
        fail_self_test "check_forbidden passed the good site without saying so"
    fi
    if ! check_images "$good/index.html" > /dev/null; then
        fail_self_test "check_images refused the good site"
    fi
    if ! check_key "$good/index.html" > /dev/null; then
        fail_self_test "check_key refused the good site"
    fi
    if ! check_local "$good" "$good/index.html" > /dev/null; then
        fail_self_test "check_local refused the good site"
    fi
    if ! check_css "$good/style.css" > /dev/null; then
        fail_self_test "check_css refused the good stylesheet"
    fi
    if ! check_nav "$good" > /dev/null; then
        fail_self_test "check_nav refused the good site"
    fi
}

# self_test_tree_and_markup <dir> <good>: a symlinked page and an unclosed
# tag refused.
self_test_tree_and_markup() {
    local dir=$1
    local good=$2

    mkdir -p "$dir/link"
    cp "$good/index.html" "$dir/link/"
    ln -s index.html "$dir/link/home.html"
    REFUSED=$((REFUSED + 1))
    if check_tree "$dir/link" > /dev/null 2>&1; then
        fail_self_test "a symlink accepted"
    fi

    mkdir -p "$dir/torn"
    sed 's|</p>||' "$good/index.html" > "$dir/torn/index.html"
    REFUSED=$((REFUSED + 1))
    if check_wellformed "$dir/torn/index.html" > /dev/null 2>&1; then
        fail_self_test "an unclosed tag accepted"
    fi
}

# self_test_page_contents <dir> <good>: a :testing reference, a page missing
# an image, a page missing the public key and a page naming an image only as
# the prefix of another refused.
self_test_page_contents() {
    local dir=$1
    local good=$2

    mkdir -p "$dir/stale"
    sed 's|bazzite-mx-nvidia-open|bazzite-mx-nvidia-open bazzite-mx:testing|' \
        "$good/index.html" > "$dir/stale/index.html"
    REFUSED=$((REFUSED + 1))
    if check_forbidden "$dir/stale/index.html" > /dev/null 2>&1; then
        fail_self_test "a :testing reference accepted"
    fi

    mkdir -p "$dir/short"
    sed "s|$REGISTRY/bazzite-mx-nvidia-open||" "$good/index.html" > "$dir/short/index.html"
    REFUSED=$((REFUSED + 1))
    if check_images "$dir/short/index.html" > /dev/null 2>&1; then
        fail_self_test "a page missing an image accepted"
    fi

    mkdir -p "$dir/nokey"
    sed "s|$KEY_URL||" "$good/index.html" > "$dir/nokey/index.html"
    REFUSED=$((REFUSED + 1))
    if check_key "$dir/nokey/index.html" > /dev/null 2>&1; then
        fail_self_test "a page missing the public key accepted"
    fi

    # bazzite-mx-nvidia inside bazzite-mx-nvidia-open does not name it.
    mkdir -p "$dir/prefix"
    sed "s| $REGISTRY/bazzite-mx-nvidia | |" "$good/index.html" > "$dir/prefix/index.html"
    REFUSED=$((REFUSED + 1))
    if check_images "$dir/prefix/index.html" > /dev/null 2>&1; then
        fail_self_test "a page naming an image only as a prefix of another accepted"
    fi
}

# self_test_links <dir> <good>: a dead external link refused; a repository
# link accepted when the file is in the fixture checkout and refused when
# it is not, never fetched.
self_test_links() {
    local dir=$1
    local good=$2
    local repo_file=https://github.com/MatrixDJ96/bazzite-mx/blob/main/docs/present.md

    REFUSED=$((REFUSED + 1))
    if check_links "$good/index.html" > /dev/null 2>&1; then
        fail_self_test "a dead link accepted"
    fi

    mkdir -p "$dir/repo/docs" "$dir/repolink"
    : > "$dir/repo/docs/present.md"
    sed "s|https://127.0.0.1:9/|$repo_file|" "$good/index.html" > "$dir/repolink/index.html"
    if ! REPO_ROOT=$dir/repo check_links "$dir/repolink/index.html" > /dev/null; then
        fail_self_test "a repository link to a present file refused"
    fi

    sed -i 's|docs/present.md|docs/absent.md|' "$dir/repolink/index.html"
    REFUSED=$((REFUSED + 1))
    if REPO_ROOT=$dir/repo check_links "$dir/repolink/index.html" > /dev/null 2>&1; then
        fail_self_test "a repository link to an absent file accepted"
    fi
}

# self_test_local_references <dir> <good>: a link to a file the site does
# not ship, an external script, a stylesheet fetched from outside and a
# plain http link refused.
self_test_local_references() {
    local dir=$1
    local good=$2

    mkdir -p "$dir/absent"
    cp "$good"/* "$dir/absent/"
    sed -i 's|href="#top"|href="absent.html"|' "$dir/absent/index.html"
    REFUSED=$((REFUSED + 1))
    if check_local "$dir/absent" "$dir/absent/index.html" > /dev/null 2>&1; then
        fail_self_test "a link to a file the site does not ship accepted"
    fi

    mkdir -p "$dir/asset"
    cp "$good"/* "$dir/asset/"
    sed -i 's|</head>|<script src="https://127.0.0.1:9/x.js"></script></head>|' \
        "$dir/asset/index.html"
    REFUSED=$((REFUSED + 1))
    if check_local "$dir/asset" "$dir/asset/index.html" > /dev/null 2>&1; then
        fail_self_test "an external asset accepted"
    fi

    mkdir -p "$dir/linkhref"
    cp "$good"/* "$dir/linkhref/"
    sed -i 's|href="style.css"|href="https://127.0.0.1:9/x.css"|' "$dir/linkhref/index.html"
    REFUSED=$((REFUSED + 1))
    if check_local "$dir/linkhref" "$dir/linkhref/index.html" > /dev/null 2>&1; then
        fail_self_test "a stylesheet fetched from outside the site accepted"
    fi

    mkdir -p "$dir/http"
    cp "$good"/* "$dir/http/"
    sed -i 's|https://127.0.0.1:9/|http://127.0.0.1:9/|' "$dir/http/index.html"
    REFUSED=$((REFUSED + 1))
    if check_local "$dir/http" "$dir/http/index.html" > /dev/null 2>&1; then
        fail_self_test "a plain http link accepted"
    fi
}

# self_test_css <dir> <good>: a url() and an @import from outside the site
# refused.
self_test_css() {
    local dir=$1
    local good=$2

    mkdir -p "$dir/css"
    cp "$good"/* "$dir/css/"
    printf 'body { background: url(https://127.0.0.1:9/bg.png); }\n' > "$dir/css/style.css"
    REFUSED=$((REFUSED + 1))
    if check_css "$dir/css/style.css" > /dev/null 2>&1; then
        fail_self_test "a stylesheet pulling from outside the site accepted"
    fi

    printf '@import "https://127.0.0.1:9/x.css";\n' > "$dir/css/style.css"
    REFUSED=$((REFUSED + 1))
    if check_css "$dir/css/style.css" > /dev/null 2>&1; then
        fail_self_test "a stylesheet importing from outside the site accepted"
    fi
}

# self_test_nav <dir> <good>: a page no nav reaches refused.
self_test_nav() {
    local dir=$1
    local good=$2

    mkdir -p "$dir/orphan"
    cp "$good"/* "$dir/orphan/"
    cp "$good/images.html" "$dir/orphan/orphan.html"
    REFUSED=$((REFUSED + 1))
    if check_nav "$dir/orphan" > /dev/null 2>&1; then
        fail_self_test "a page no nav reaches accepted"
    fi
}

self_test() {
    local dir good

    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    good=$dir/good

    self_test_write_good_site "$good"
    self_test_good_site_accepted "$good"
    self_test_tree_and_markup "$dir" "$good"
    self_test_page_contents "$dir" "$good"
    self_test_links "$dir" "$good"
    self_test_local_references "$dir" "$good"
    self_test_css "$dir" "$good"
    self_test_nav "$dir" "$good"

    echo "self-test ok: 1 good site accepted, $REFUSED bad inputs refused"
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "" | -*)
        exit_with_error "usage: check-site.sh <dir> [--offline] | --self-test"
        ;;
    *)
        offline=false
        if [ "${2:-}" = "--offline" ]; then
            offline=true
        fi
        check_site "$1" "$offline"
        ;;
esac
