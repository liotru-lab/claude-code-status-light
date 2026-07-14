# Releasing CC Status Light

Direct, notarized macOS builds published as GitHub Releases, cut from your Mac
with `scripts/release.sh` — no CI, no stored secrets.

```sh
./scripts/release.sh v0.1.0
```

That builds a Release `.app`, signs it with your **Developer ID Application**
certificate, notarizes + staples it with Apple, zips it, tags the commit, and
creates the GitHub Release (as the `liotru` gh account) with the zip attached.

## One-time setup

### 1. Developer ID Application certificate

Distributing outside the App Store needs a **Developer ID Application** cert
(the `Apple Development` certs we build with locally are not valid for
distribution). Create one under the **Liotru ltd EOOD** team (`38LKT4ZSN5`):

- Xcode ▸ **Settings ▸ Accounts** ▸ select the Liotru team ▸ **Manage
  Certificates…** ▸ **+** ▸ **Developer ID Application**.

Confirm it landed in your keychain:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Notarization credentials

Store a `notarytool` keychain profile once (the script uses profile name
`CCStatusLight`). Use an **app-specific password** (create at appleid.apple.com ▸
Sign-In & Security ▸ App-Specific Passwords):

```sh
xcrun notarytool store-credentials CCStatusLight \
  --apple-id you@example.com \
  --team-id 38LKT4ZSN5 \
  --password <app-specific-password>
```

(Alternatively an App Store Connect API key — see `xcrun notarytool
store-credentials --help`.)

## Cutting a release

```sh
git checkout main            # release from main
git pull
./scripts/release.sh v0.1.0  # tag must be vX.Y.Z
```

The version (`0.1.0`) also becomes the app's `MARKETING_VERSION` via the tag.

### Environment overrides

| Var | Default | Purpose |
| --- | --- | --- |
| `DEVID_IDENTITY` | auto-detected | signing identity string |
| `TEAM_ID` | `38LKT4ZSN5` | Apple team id |
| `NOTARY_PROFILE` | `CCStatusLight` | notarytool keychain profile |
| `GH_USER` | `liotru` | gh account with rights on the repo |
| `REPO` | `liotru-lab/claude-code-status-light` | target repo |
| `SKIP_RELEASE=1` | — | build + notarize + staple only, no GitHub Release |

## Verifying a release

After download, a user can confirm it's notarized:

```sh
spctl -a -t exec -vvv /Applications/CCStatusLight.app   # → accepted, source=Notarized Developer ID
xcrun stapler validate /Applications/CCStatusLight.app
```

## Mac App Store

Not offered — see the note in [README](README.md#distribution). The app is
intentionally non-sandboxed; the App Store requires the App Sandbox, which
conflicts with reading `~/.claude` transcripts and sharing a state directory with
the (outside-sandbox) hook. Shipping on the App Store would require an
architectural rework, tracked as future work.
