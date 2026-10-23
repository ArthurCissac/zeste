#!/bin/zsh
# Image disque d'installation soignée : fond Zeste, flèche vers Applications, icône de volume.
# La mise en page est écrite par dmgbuild (vendor/py), sans piloter le Finder : les dernières
# versions de macOS n'enregistrent plus les options d'affichage envoyées par AppleScript.
# Usage : scripts/make-dmg.sh <Zeste.app> <sortie.dmg>
set -euo pipefail
cd "$(dirname "$0")/.."
APP=$1; OUT=$2
WORK=build/dmg-work
rm -rf "$WORK" && mkdir -p "$WORK"

if [[ ! -x vendor/py/bin/dmgbuild ]]; then
  python3 -m venv vendor/py && vendor/py/bin/pip install -q dmgbuild
fi

swift scripts/make-dmg-background.swift "$WORK"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/bg.tiff" >/dev/null

rm -f "$OUT"
vendor/py/bin/dmgbuild -s scripts/dmg-settings.py \
  -D app="$APP" -D icon=build/AppIcon.icns -D bg="$WORK/bg.tiff" \
  "Zeste" "$OUT"
echo "Image disque : $OUT"
