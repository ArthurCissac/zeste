#!/bin/zsh
# Compile Zeste, assemble Zeste.app, la signe localement et l'installe dans ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Zeste.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Zeste "$APP/Contents/MacOS/Zeste"

# Icône
if [[ ! -f build/AppIcon.icns ]]; then
  mkdir -p build/AppIcon.iconset
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Zeste</string>
  <key>CFBundleDisplayName</key><string>Zeste</string>
  <key>CFBundleIdentifier</key><string>com.arthurcissac.zeste</string>
  <key>CFBundleExecutable</key><string>Zeste</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Zeste pilote le Finder (sélection) et Pages, Keynote ou Numbers pour convertir vos documents, sur votre Mac.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

DEST="$HOME/Applications/Zeste.app"
mkdir -p "$HOME/Applications"
pkill -x Zeste 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installé : $DEST"
