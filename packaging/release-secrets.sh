#!/usr/bin/env bash
# Store the signing and notarization secrets .github/workflows/release.yml uses,
# so releases open without the Gatekeeper "Open Anyway" step. Needs:
#   - an Apple Developer Program membership;
#   - a "Developer ID Application" certificate in your keychain, exported from
#     Keychain Access as a .p12 (with a password you choose);
#   - an app-specific password for your Apple ID (account.apple.com → Sign-In and
#     Security → App-Specific Passwords).
# Every value is read here and piped straight into `gh secret set`; nothing is
# written to disk or echoed.
#
# The target is the remote whose URL contains github.com, whatever it is called,
# so a clone with more remotes still sets the secrets on the right repo.
# Override with REPO=owner/name (or REMOTE=<remote name>).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${REPO:-}" ]; then
  REMOTE="${REMOTE:-$(git remote -v | awk '$2 ~ /github\.com/ {print $1; exit}')}"
  [ -n "$REMOTE" ] || { echo "no GitHub remote found; set REPO=owner/name" >&2; exit 1; }
  url=$(git remote get-url "$REMOTE") || exit 1
  [[ "$url" == *github.com* ]] || { echo "remote '$REMOTE' is not a GitHub remote ($url)" >&2; exit 1; }
  REPO=$(sed -E 's#^.*github\.com[:/]+##; s#/$##; s#\.git$##' <<< "$url")
fi
[[ "$REPO" =~ ^[^/]+/[^/]+$ ]] || { echo "expected REPO=owner/name, got '$REPO'" >&2; exit 1; }
put() { gh secret set "$1" --repo "$REPO" > /dev/null && echo "  set $1"; }

echo "Secrets for $REPO"
read -r -p "Developer ID Application .p12 file: " P12
P12="${P12/#\~/$HOME}"
[ -f "$P12" ] || { echo "no such file: $P12" >&2; exit 1; }
base64 -i "$P12" | put MACOS_CERTIFICATE_P12
read -r -s -p ".p12 password: " value; echo
printf '%s' "$value" | put MACOS_CERTIFICATE_PASSWORD

identity=$(security find-identity -v -p codesigning 2> /dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')
read -r -p "Signing identity [${identity:-none found}]: " value
identity="${value:-$identity}"
[[ "$identity" == "Developer ID Application"* ]] \
    || { echo "a Developer ID Application identity is needed" >&2; exit 1; }
printf '%s' "$identity" | put MACOS_SIGNING_IDENTITY

read -r -p "Apple ID (email): " value
printf '%s' "$value" | put APPLE_ID
team=$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<< "$identity")
read -r -p "Team ID [${team:-?}]: " value
printf '%s' "${value:-$team}" | put APPLE_TEAM_ID
read -r -s -p "App-specific password: " value; echo
printf '%s' "$value" | put APPLE_APP_PASSWORD

echo "Done: the next 'mise run release X.Y.Z' is signed and notarized."
