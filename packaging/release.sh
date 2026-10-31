#!/usr/bin/env bash
# Cut a release of CacheBar from a clean, pushed main.
#
#   release.sh 1.2.0           build + test here, then tag v1.2.0 and push the tag;
#                              GitHub Actions (release.yml) builds and publishes it
#   release.sh --local 1.2.0   build + test here, then publish this Mac's build
#                              with `gh release create` (no Actions needed)
#
# This repo has two remotes: `origin` is GitLab, `github` is GitHub. Releases live
# on GitHub, so the remote whose URL contains github.com is used to compare main,
# push the tag and address `gh` (which has no default repo here). REMOTE=<name>
# overrides the detection.
#
# Releases are signed with a "Developer ID Application" identity when the
# keychain has one (or CODESIGN_IDENTITY names one), otherwise ad-hoc — never
# with an Apple Development certificate, whose signature carries the developer's
# personal Apple ID into every download.
set -euo pipefail

LOCAL=0
if [ "${1:-}" = "--local" ]; then
    LOCAL=1
    shift
fi
VERSION="${1:-}"
VERSION="${VERSION#v}"
TAG="v$VERSION"
cd "$(dirname "$0")/.."

die() { echo "release: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
    || die "give a version like 1.2.0 (got '${1:-}')"
git rev-parse --git-dir > /dev/null 2>&1 || die "not a git repository"
[ -z "$(git status --porcelain)" ] || die "uncommitted changes; commit or stash them first"
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = main ] || die "on '$branch'; releases are cut from main"
git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && die "tag $TAG already exists"

REMOTE="${REMOTE:-$(git remote -v | awk '$2 ~ /github\.com/ {print $1; exit}')}"
[ -n "$REMOTE" ] || die "no GitHub remote (none has github.com in its URL); set REMOTE=<name>"
REMOTE_URL=$(git remote get-url "$REMOTE" 2> /dev/null) || die "no such remote: $REMOTE"
[[ "$REMOTE_URL" == *github.com* ]] || die "remote '$REMOTE' is not a GitHub remote ($REMOTE_URL)"
GH_REPO=$(sed -E 's#^.*github\.com[:/]+##; s#/$##; s#\.git$##' <<< "$REMOTE_URL")
[[ "$GH_REPO" =~ ^[^/]+/[^/]+$ ]] || die "cannot read owner/repo from '$REMOTE_URL'"

git fetch -q "$REMOTE" main
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$REMOTE/main")" ] \
    || die "main differs from $REMOTE/main; push or pull first"

[ -x tests/script-tests.sh ] || die "tests/script-tests.sh is missing or not executable"
[ -x tests/e2e.sh ] || die "tests/e2e.sh is missing or not executable"

echo "→ build, script tests and end-to-end tests"
packaging/build.sh
tests/script-tests.sh
tests/e2e.sh

if [ "$LOCAL" = 0 ]; then
    git tag -a "$TAG" -m "CacheBar $VERSION"
    git push "$REMOTE" "$TAG"
    echo "→ pushed $TAG to $REMOTE; GitHub Actions builds and publishes the release:"
    echo "  https://github.com/$GH_REPO/actions/workflows/release.yml"
    exit 0
fi

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2> /dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
echo "→ universal build ${IDENTITY:+signed by $IDENTITY}"
rm -rf dist
VERSION="$VERSION" UNIVERSAL=1 SHARED=1 CODESIGN_IDENTITY="${IDENTITY:--}" packaging/build.sh dist/CacheBar.app
ditto -c -k --keepParent dist/CacheBar.app dist/CacheBar.zip
(cd dist && shasum -a 256 CacheBar.zip > CacheBar.zip.sha256)

notes="Download **CacheBar.zip**, unzip it and move **CacheBar.app** to Applications.
Requires macOS 14 or later and Claude Code, plus Python 3 (Apple's Command Line Tools:
\`xcode-select --install\`, or any python3); runs on Apple silicon and Intel.

This build is not notarized. On first launch macOS will refuse to open it: open
**System Settings → Privacy & Security** and click **Open Anyway**, or run
\`xattr -dr com.apple.quarantine /Applications/CacheBar.app\`."

# Creating the release also creates the tag on GitHub; release.yml sees the
# existing release and stands down instead of building a second copy.
gh release create "$TAG" dist/CacheBar.zip dist/CacheBar.zip.sha256 \
    --repo "$GH_REPO" --target "$(git rev-parse HEAD)" --title "CacheBar $VERSION" \
    --notes "$notes" --generate-notes
git fetch -q --tags "$REMOTE"
echo "→ published $TAG"
