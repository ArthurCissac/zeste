#!/bin/zsh
# Fabrique Zeste.dmg, signé Developer ID et notarisé par Apple, prêt à envoyer.
# Prérequis (une seule fois, mot de passe pour app saisi par toi) :
#   xcrun notarytool store-credentials zeste --apple-id <ton e-mail Apple> --team-id 8222G9B2DZ
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE=${PROFILE:-zeste}

./scripts/build-app.sh
APP=build/Zeste.app
SIGN=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
[[ -n "$SIGN" ]] || { echo "Certificat Developer ID introuvable"; exit 1; }

# 1. Notarisation de l'app, puis agrafage du ticket (l'app s'ouvre même hors ligne).
ditto -c -k --keepParent "$APP" build/Zeste-notarize.zip
xcrun notarytool submit build/Zeste-notarize.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

# 2. Image disque avec un raccourci vers Applications.
VERSION=$(cat VERSION 2>/dev/null || echo 1.0)
DMG=build/Zeste-$VERSION.dmg
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Zeste" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN" "$DMG"

# 3. Notarisation de l'image disque.
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

cp "$DMG" "$HOME/Desktop/"
echo "Prêt à partager : $HOME/Desktop/$(basename $DMG)"
