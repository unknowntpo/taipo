#!/bin/bash
# Build Taipo.app (input method) and the Taipo desktop app (switches), then install them
# (Spec 002 Behavior 13, Spec 004 D6). xcodebuild is required so MLX's Metal shaders
# are compiled (`xcodebuild -downloadComponent MetalToolchain` once per machine).
#   scripts/install-ime.sh            build + install
#   scripts/install-ime.sh --build    build only (output: .build/Taipo.app, .build/app/Taipo.app)
set -euo pipefail
cd "$(dirname "$0")/.."
PRODUCTS=.build/xcode/Build/Products/Release
APP=.build/Taipo.app
SETTINGS=".build/app/Taipo.app"
DEST="$HOME/Library/Input Methods/Taipo.app"
SETTINGS_DEST="$HOME/Applications/Taipo.app"

for scheme in TaipoIMEApp TaipoSettingsApp; do
  xcodebuild -scheme "$scheme" -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath .build/xcode -skipPackagePluginValidation -skipMacroValidation -quiet build
done

bundle_resources() {  # $1 = .app path
  cp -R "$PRODUCTS"/*.bundle "$1/Contents/Resources/"
  cp Sources/TaipoCore/Resources/zh.tsv Sources/TaipoCore/Resources/en.tsv THIRD_PARTY_NOTICES.md "$1/Contents/Resources/"
}

rm -rf "$APP" "$SETTINGS"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$SETTINGS/Contents/MacOS" "$SETTINGS/Contents/Resources"
cp "$PRODUCTS/TaipoIMEApp" "$APP/Contents/MacOS/Taipo"
# Spec 012: whisper.cpp ships as a dynamic framework (@rpath/whisper.framework); embed it.
cp -R "$PRODUCTS/whisper.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Taipo"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp -R Packaging/*.lproj "$APP/Contents/Resources/"
bundle_resources "$APP"
swift scripts/make-icon.swift "$APP/Contents/Resources/taipo.tiff"
cp "$PRODUCTS/TaipoSettingsApp" "$SETTINGS/Contents/MacOS/Taipo"
cp Packaging/Settings-Info.plist "$SETTINGS/Contents/Info.plist"
bundle_resources "$SETTINGS"
for app in "$APP" "$SETTINGS"; do
  plutil -lint "$app/Contents/Info.plist" >/dev/null
  codesign --force --deep --sign - "$app"
  codesign --verify --strict "$app"
done
echo "built $APP and $SETTINGS"
[[ "${1:-}" == "--build" ]] && exit 0

pkill -x Taipo 2>/dev/null || true  # input method and desktop app share the process name
mkdir -p "$HOME/Library/Input Methods" "$HOME/Applications"
rm -rf "$DEST" "$SETTINGS_DEST"
cp -R "$APP" "$DEST"
cp -R "$SETTINGS" "$SETTINGS_DEST"
echo "installed $DEST and $SETTINGS_DEST"
swift scripts/register-ime.swift "$DEST"
echo "Enable: System Settings → Keyboard → Text Input → Edit… → + → 繁體中文 → Taipo"
