#!/usr/bin/env bash
# install.sh — download and install the latest CC Status Light release.
#
#   curl -fsSL https://raw.githubusercontent.com/liotru-lab/claude-code-status-light/main/install.sh | bash
#
# Fetches the latest notarized build from GitHub Releases, unpacks it, and moves
# CCStatusLight.app into /Applications. No CLI to symlink; no sudo unless
# /Applications isn't writable. Because it's downloaded with curl (not a browser)
# the app isn't quarantined, so it opens with no Gatekeeper prompt.
#
# Env overrides:
#   REPO         GitHub repo        (default: liotru-lab/claude-code-status-light)
#   INSTALL_DIR  install location   (default: /Applications)

set -euo pipefail

REPO="${REPO:-liotru-lab/claude-code-status-light}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP="CCStatusLight.app"

info()  { printf '  %s\n' "$*"; }
warn()  { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
error() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || error "CC Status Light is macOS only."

command -v curl  >/dev/null 2>&1 || error "curl is required."
command -v ditto >/dev/null 2>&1 || error "ditto is required (ships with macOS)."

printf '\033[1mInstalling CC Status Light\033[0m\n\n'

# --- find the latest release's .zip asset -----------------------------------
info "Looking up the latest release…"
api="https://api.github.com/repos/${REPO}/releases/latest"
release_json="$(curl -fsSL "$api" 2>/dev/null)" \
  || error "Couldn't reach the releases API. Is the repo public and published?"

tag="$(printf '%s' "$release_json" \
  | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"tag_name": *"//; s/"$//')"
asset_url="$(printf '%s' "$release_json" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 \
  | sed 's/.*"browser_download_url": *"//; s/"$//')"

[[ -n "$asset_url" ]] || error "No .zip asset found in the latest release."
info "Found ${tag:-latest}."

# --- download + unpack ------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

info "Downloading…"
curl -fsSL "$asset_url" -o "$tmp/app.zip" || error "Download failed."

info "Unpacking…"
ditto -x -k "$tmp/app.zip" "$tmp/unpacked" || error "Unpack failed."

src="$(/usr/bin/find "$tmp/unpacked" -maxdepth 2 -name "$APP" -type d | head -1)"
[[ -n "$src" ]] || error "$APP not found in the downloaded archive."

# --- install to /Applications ----------------------------------------------
dst="$INSTALL_DIR/$APP"
if [[ -w "$INSTALL_DIR" ]]; then
  rm -rf "$dst"; cp -R "$src" "$dst"
else
  warn "$INSTALL_DIR isn't writable — using sudo (you may be prompted)."
  sudo rm -rf "$dst"; sudo cp -R "$src" "$dst"
fi
info "Installed to $dst"

printf '\n\033[32m✓ CC Status Light installed.\033[0m\n\n'
info "Next steps:"
info "  1. Open it:            open -a \"CC Status Light\""
info "  2. Wire the hooks:     in the app, choose  CC Status Light ▸ Install Hooks…"
info "  3. Start a Claude Code session — it appears in the window."
