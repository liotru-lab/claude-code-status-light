#!/usr/bin/env bash
#
# CC Status Light — local release pipeline.
#
#   ./scripts/release.sh v0.1.0
#
# Builds a Release .app, signs it with a Developer ID Application certificate,
# notarizes and staples it, zips it, and creates a GitHub Release with the zip
# attached. Everything runs on your Mac using your local keychain — no CI secrets.
#
# One-time setup is documented in RELEASE.md (create the Developer ID cert and a
# notarytool credential profile). See that file if any precondition below fails.
#
# Environment overrides:
#   DEVID_IDENTITY   signing identity (default: the one "Developer ID Application"
#                    cert found in the keychain)
#   TEAM_ID          Apple team id (default: 38LKT4ZSN5)
#   NOTARY_PROFILE   notarytool keychain profile name (default: CCStatusLight)
#   GH_USER          gh account with rights on liotru-lab (default: liotru)
#   REPO             GitHub repo (default: liotru-lab/claude-code-status-light)
#   SKIP_RELEASE=1   build + notarize + staple, but don't create the GitHub Release

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEAM_ID="${TEAM_ID:-38LKT4ZSN5}"
NOTARY_PROFILE="${NOTARY_PROFILE:-CCStatusLight}"
GH_USER="${GH_USER:-liotru}"
REPO="${REPO:-liotru-lab/claude-code-status-light}"
APP_NAME="CCStatusLight"
DISPLAY="CC Status Light"

die() { echo "release: $*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# --- args -------------------------------------------------------------------
TAG="${1:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: $0 vX.Y.Z   (got '${TAG:-}')"
VERSION="${TAG#v}"

# --- preconditions ----------------------------------------------------------
step "Checking tools"
for t in xcodegen xcodebuild codesign ditto xcrun; do
  command -v "$t" >/dev/null 2>&1 || die "'$t' not found on PATH"
done
xcrun notarytool --version >/dev/null 2>&1 || die "xcrun notarytool unavailable (need Xcode 13+)"

step "Finding Developer ID Application identity"
if [[ -z "${DEVID_IDENTITY:-}" ]]; then
  DEVID_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/^[^"]*"([^"]+)".*/\1/')"
fi
[[ -n "$DEVID_IDENTITY" ]] || die "no 'Developer ID Application' certificate in the keychain.
  Create one (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application),
  then see RELEASE.md."
echo "identity: $DEVID_IDENTITY"

step "Checking notarytool credentials ($NOTARY_PROFILE)"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' not set up.
  Run: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
         --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>
  (see RELEASE.md)"

# --- build ------------------------------------------------------------------
OUT="build/release"
rm -rf "$OUT"; mkdir -p "$OUT"

step "Generating Xcode project"
xcodegen generate >/dev/null

step "Building Release (signed, hardened runtime)"
xcodebuild -project "$APP_NAME.xcodeproj" -target "$APP_NAME" -configuration Release \
  -arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO \
  CONFIGURATION_BUILD_DIR="$PWD/$OUT" \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVID_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  build >/dev/null

APP="$OUT/$APP_NAME.app"
[[ -d "$APP" ]] || die "build produced no app at $APP"

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|flags.*runtime" || true

# --- notarize ---------------------------------------------------------------
ZIP_NOTARY="$OUT/$APP_NAME-notarize.zip"
step "Zipping for notarization"
ditto -c -k --keepParent "$APP" "$ZIP_NOTARY"

step "Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$ZIP_NOTARY" --keychain-profile "$NOTARY_PROFILE" --wait

step "Stapling ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec -vvv "$APP" 2>&1 | head -3 || true

# --- package ----------------------------------------------------------------
DIST="$OUT/$DISPLAY $VERSION.zip"
step "Packaging distributable zip"
ditto -c -k --keepParent "$APP" "$DIST"
echo "artifact: $DIST"

# --- github release ---------------------------------------------------------
if [[ "${SKIP_RELEASE:-0}" == "1" ]]; then
  step "SKIP_RELEASE=1 — not creating a GitHub Release"
  echo "Done. Upload '$DIST' manually if you like."
  exit 0
fi

command -v gh >/dev/null 2>&1 || die "gh not found; set SKIP_RELEASE=1 to skip the GitHub Release"

step "Tagging $TAG at HEAD and pushing"
git rev-parse "$TAG" >/dev/null 2>&1 || git tag -a "$TAG" -m "$DISPLAY $VERSION"
git push origin "$TAG"

step "Creating GitHub Release $TAG (as '$GH_USER')"
PREV_GH="$(gh api user --jq .login 2>/dev/null || true)"
switch_back() { [[ -n "${PREV_GH:-}" && "$PREV_GH" != "$GH_USER" ]] && gh auth switch -u "$PREV_GH" >/dev/null 2>&1 || true; }
trap switch_back EXIT
gh auth switch -u "$GH_USER" >/dev/null 2>&1 || die "couldn't switch gh to '$GH_USER'"

gh release create "$TAG" "$DIST" \
  --repo "$REPO" \
  --title "$DISPLAY $VERSION" \
  --verify-tag \
  --notes "Notarized macOS build. Requires macOS 15+. Unzip and move CCStatusLight.app to /Applications."

step "Done"
echo "Released $TAG → https://github.com/$REPO/releases/tag/$TAG"
