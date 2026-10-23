#!/bin/zsh
# Image disque d'installation soignée : fond Zeste, flèche vers Applications, icône de volume.
# Usage : scripts/make-dmg.sh <Zeste.app> <sortie.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."
APP=$1; OUT=$2
VOL=Zeste
WORK=build/dmg-work
rm -rf "$WORK" && mkdir -p "$WORK/stage/.background"

swift scripts/make-dmg-background.swift "$WORK"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/stage/.background/bg.tiff" >/dev/null
cp -R "$APP" "$WORK/stage/Zeste.app"
ln -s /Applications "$WORK/stage/Applications"
cp build/AppIcon.icns "$WORK/stage/.VolumeIcon.icns"

# Un volume « Zeste » déjà monté (ancien dmg ouvert) ferait échouer la mise en page.
for v in /Volumes/$VOL*(N); do hdiutil detach "$v" -force >/dev/null 2>&1 || true; done

hdiutil create -srcfolder "$WORK/stage" -volname "$VOL" -fs HFS+ -format UDRW -size 160m "$WORK/rw.dmg" >/dev/null
DEV=$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | grep -E '^/dev/' | head -1 | awk '{print $1}')
MNT=/Volumes/$VOL
sleep 1

# Icône du volume (attribut « icône personnalisée »).
if command -v SetFile >/dev/null; then SetFile -a C "$MNT"; fi

# Mise en page du Finder : 660 × 420, sans barre d'outils, icônes placées sur le fond.
osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set sidebar width of container window to 0
    set the bounds of container window to {200, 120, 860, 568}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set label position of opts to bottom
    set background picture of opts to file ".background:bg.tiff"
    set position of item "Zeste.app" of container window to {175, 200}
    set position of item "Applications" of container window to {485, 200}
    update without registering applications
    delay 1
    close
    open
    delay 2
    close
  end tell
end tell
OSA

chmod -Rf go-w "$MNT" 2>/dev/null || true
sync
hdiutil detach "$DEV" >/dev/null
rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "Image disque : $OUT"
