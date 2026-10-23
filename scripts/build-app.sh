#!/bin/zsh
# Compile Zeste, assemble Zeste.app (ffmpeg embarqué), le signe et l'installe dans ~/Applications.
#   ./scripts/build-app.sh            signature Developer ID si disponible, sinon locale
#   SIGN=- ./scripts/build-app.sh     force la signature locale
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Zeste.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/Licences"
cp .build/release/Zeste "$APP/Contents/MacOS/Zeste"

# ffmpeg autonome (voir scripts/build-ffmpeg.sh)
FF=vendor/ffmpeg-8.0
if [[ -x $FF/ffmpeg && -x $FF/ffprobe ]]; then
  cp $FF/ffmpeg $FF/ffprobe "$APP/Contents/Resources/bin/"
  cp $FF/COPYING.LGPLv2.1 "$APP/Contents/Resources/Licences/FFmpeg-LGPL-2.1.txt"
  for d in vendor/src/*/; do
    n=$(basename $d)
    for f in COPYING LICENSE PATENTS; do [[ -f $d$f ]] && cp $d$f "$APP/Contents/Resources/Licences/$n-$f.txt"; done
  done
  cp NOTICE.txt "$APP/Contents/Resources/Licences/"
else
  echo "⚠️  ffmpeg embarqué absent : lance scripts/build-ffmpeg.sh (sinon l'app dépend de Homebrew)"
fi

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

VERSION=$(cat VERSION 2>/dev/null || echo 1.0)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Zeste</string>
  <key>CFBundleDisplayName</key><string>Zeste</string>
  <key>CFBundleIdentifier</key><string>com.arthurcissac.zeste</string>
  <key>CFBundleExecutable</key><string>Zeste</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Zeste — Arthur Cissac. FFmpeg sous licence LGPL 2.1 (voir Resources/Licences).</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Zeste transcrit l'audio de vos vidéos pour créer des sous-titres, entièrement sur votre Mac.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Zeste pilote le Finder (sélection) et Pages, Keynote ou Numbers pour convertir vos documents, sur votre Mac.</string>
</dict>
</plist>
PLIST

# Signature : Developer ID + runtime renforcé (requis pour la notarisation Apple).
SIGN=${SIGN:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}
if [[ -n "$SIGN" && "$SIGN" != "-" ]]; then
  for bin in "$APP"/Contents/Resources/bin/*(N); do
    codesign --force --timestamp --options runtime --sign "$SIGN" "$bin"
  done
  codesign --force --timestamp --options runtime --entitlements scripts/Zeste.entitlements --sign "$SIGN" "$APP"
  echo "Signé : $SIGN"
else
  codesign --force --deep --sign - "$APP"
  echo "Signature locale (non distribuable)"
fi
codesign --verify --strict --deep "$APP"

DEST="$HOME/Applications/Zeste.app"
mkdir -p "$HOME/Applications"
pkill -x Zeste 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installé : $DEST"
