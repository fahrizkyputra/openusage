#!/usr/bin/env bash
set -euo pipefail

# Team build (fork-only). Builds a universal (arm64 + x86_64) OpenUsage.app with the 9router and
# 9router Kitchen providers and packages it as a zip with install notes, for sharing inside the team.
#
# Differences from the official release (script/release.sh):
#   - own bundle id ($TEAM_BUNDLE_ID), so it never collides with an installed official app;
#   - ad-hoc signed and NOT notarized (no Apple Developer account) — users must clear Gatekeeper once;
#   - no Sparkle feed (no auto-updates) and no iCloud entitlement;
#   - telemetry disabled in source on this branch (see TelemetryConfig).
#
# Output: dist/team/OpenUsage-Team-<version>.zip  (contains OpenUsage.app + INSTALL.md)
# Env (required — organisation-specific values stay out of this repo):
#   TEAM_BUNDLE_ID    bundle id, e.g. com.example.openusage.team
#   TEAM_KITCHEN_URL  9router Kitchen host baked into Info.plist, e.g. https://kitchen.example.com
#   TEAM_UPDATE_REPO  owner/name of the private repo whose GitHub Releases the in-app update banner checks
# Env (optional):
#   TEAM_VERSION      version string (default: 0.7.0-team.<commit count>)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="OpenUsage"
BUNDLE_ID="${TEAM_BUNDLE_ID:?set TEAM_BUNDLE_ID (e.g. com.example.openusage.team)}"
KITCHEN_URL="${TEAM_KITCHEN_URL:?set TEAM_KITCHEN_URL (e.g. https://kitchen.example.com)}"
case "$KITCHEN_URL" in https://*|http://*) ;; *) echo "TEAM_KITCHEN_URL must be an http(s) URL" >&2; exit 1 ;; esac
KITCHEN_URL="${KITCHEN_URL%/}"
KITCHEN_HOST="${KITCHEN_URL#*://}"
UPDATE_REPO="${TEAM_UPDATE_REPO:?set TEAM_UPDATE_REPO (e.g. example/openusage-team)}"
echo "$UPDATE_REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || { echo "TEAM_UPDATE_REPO must be owner/name" >&2; exit 1; }
MIN_SYSTEM_VERSION="15.0"
BUILD="$(git rev-list --count HEAD)"
VERSION="${TEAM_VERSION:-0.7.0-team.$BUILD}"
COMMIT="$(git rev-parse --short HEAD)"

OUT_DIR="$ROOT_DIR/dist/team"
APP_BUNDLE="$OUT_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
CLI_BINARY="$APP_HELPERS/openusage"
ZIP_PATH="$OUT_DIR/$APP_NAME-Team-$VERSION.zip"

# Refuse to package a build that still phones home to upstream PostHog.
if grep -q 'bakedToken = "phc_' Sources/OpenUsage/Services/Telemetry.swift; then
  echo "Telemetry token still baked in — team builds must ship with telemetry disabled." >&2
  exit 1
fi

echo "==> building $APP_NAME $VERSION ($COMMIT) — universal (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 --product OpenUsage
swift build -c release --arch arm64 --arch x86_64 --product openusage-cli
BUILD_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> staging $APP_BUNDLE"
rm -rf "$OUT_DIR"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_DIR/$APP_NAME" "$APP_BINARY"
cp "$BUILD_DIR/openusage-cli" "$CLI_BINARY"
chmod +x "$APP_BINARY" "$CLI_BINARY"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CLI_BINARY"
for binary in "$APP_BINARY" "$CLI_BINARY"; do
  lipo -archs "$binary" | grep -q x86_64 && lipo -archs "$binary" | grep -q arm64 \
    || { echo "Expected a universal binary, got: $(lipo -archs "$binary") ($binary)" >&2; exit 1; }
done

# Same SDK restamp as release.sh, so AppKit uses the modern (Liquid Glass) controls on Tahoe.
vtool -set-build-version macos "$MIN_SYSTEM_VERSION" 26.0 -replace -output "$APP_BINARY.tmp" "$APP_BINARY"
mv "$APP_BINARY.tmp" "$APP_BINARY"
chmod +x "$APP_BINARY"

shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob
# Universal (multi --arch) builds emit a standard macOS bundle layout (Contents/Resources/…) while a
# single-arch build is flat, so look for the icon anywhere inside the resource bundle.
if [ -z "$(find "$APP_RESOURCES/OpenUsage_OpenUsage.bundle" -name 9router.svg -print -quit 2>/dev/null)" ]; then
  echo "9router icon missing from the resource bundle; bundle contents:" >&2
  find "$APP_RESOURCES" -maxdepth 4 >&2 || true
  exit 1
fi

cp "$ROOT_DIR/assets/AppIcon.prebuilt/Assets.car" "$APP_RESOURCES/Assets.car"
cp "$ROOT_DIR/assets/AppIcon.prebuilt/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"

cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NineRouterKitchenURL</key><string>$KITCHEN_URL</string>
  <key>TeamUpdateRepo</key><string>$UPDATE_REPO</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: Sparkle framework first (not --deep on the app so it keeps its own signature).
"$ROOT_DIR/script/embed_sparkle.sh" "$APP_BUNDLE" "$APP_BINARY" "-" ""
codesign --force --sign - "$CLI_BINARY"
codesign --force --sign - --entitlements "$ROOT_DIR/script/OpenUsage.local.entitlements.plist" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

cat >"$OUT_DIR/INSTALL.md" <<'EOF'
# OpenUsage (Team build) — 9router + 9router Kitchen

Menu-bar app that shows AI usage: 9router (local gateway), 9router Kitchen (@KITCHEN_HOST@),
plus Claude, Codex, Cursor, Copilot, and other providers you are logged in to on this Mac.

Requirements: macOS 15 (Sequoia) or later, Apple Silicon or Intel.

## Install

1. Unzip, then drag `OpenUsage.app` into `/Applications`.
2. This build is not notarized by Apple, so macOS blocks it the first time. Open Terminal and run:

       xattr -dr com.apple.quarantine /Applications/OpenUsage.app

   (Or: open the app once, then System Settings → Privacy & Security → "Open Anyway".)
3. Open OpenUsage. Its icon appears in the menu bar (there is no Dock icon).
4. macOS may ask whether OpenUsage can use items in your Keychain (e.g. "Claude Code-credentials").
   That is how it reads the Claude / Cursor logins already on this Mac — click **Always Allow**.
   Because this build is ad-hoc signed, macOS asks again after you install a newer zip.

## 9router Kitchen

Click the menu-bar icon → Customize → **9router Kitchen** → API Key, paste a 9router API key that is
active on @KITCHEN_HOST@, and Save. It is stored only on this Mac, in
`~/.config/openusage/9router-kitchen.json`, readable by your macOS account only.

## 9router (local)

Shows automatically if 9router runs on this Mac (`http://localhost:20128`). Otherwise leave it off.

## Notes

- Session / Weekly show the upstream account closest to its limit, named beside the row
  (e.g. "Weekly · Account 1"). Today / Last 7 Days / Last 30 Days are totals across all accounts.
- Updates: when a newer release exists, the dashboard shows "New version available". Click
  "Update now" and follow the steps (it gives you a prompt for your coding agent).
- Telemetry is disabled in this build; nothing is sent to OpenUsage's analytics.
- Command line: `/Applications/OpenUsage.app/Contents/Helpers/openusage 9router-kitchen`
EOF
sed -i '' "s#@KITCHEN_HOST@#$KITCHEN_HOST#g" "$OUT_DIR/INSTALL.md"
printf '\nBuild: %s (%s)\n' "$VERSION" "$COMMIT" >>"$OUT_DIR/INSTALL.md"

echo "==> zipping $ZIP_PATH"
# ditto keeps the Sparkle framework's symlinks and the code signature intact (plain `zip` breaks both).
STAGE="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$STAGE/"
cp "$OUT_DIR/INSTALL.md" "$STAGE/"
(cd "$STAGE" && ditto -c -k --sequesterRsrc . "$ZIP_PATH")
rm -rf "$STAGE"
echo "==> done: $ZIP_PATH"
