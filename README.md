# Zeste

Convertisseur de fichiers hors ligne pour Mac, dans la barre des menus. Usage personnel d'Arthur,
écrit de zéro (aucun code, nom ni visuel repris d'une autre app).

## Utilisation

Glisser un ou plusieurs fichiers, et sans lâcher, appuyer sur :

| Touche | Roue | Exemples |
|---|---|---|
| ⇧ | Convertir | JPG, PNG, WebP, HEIC, AVIF, MP4, WebM, GIF, MP3, PDF, Word, EPUB… |
| ⌘ | Outils | compresser, redimensionner, couper, découper, fusionner, favicon… |
| ⌃ | Actions | AirDrop, flotter, copier, déplacer, copier le chemin, Terminal |
| ⌥ | Extras | formats réseaux sociaux, sous-titres auto, lire texte et QR, poids cible |
| ⇧⌘ | Éditer | retoucher une photo ou une vidéo, retirer le fond, couper avec la forme d'onde |

Déposer sur une part de la roue ; au centre, on annule. Le résultat arrive à côté de l'original
(réglable). Sans souris : sélection Finder + ⌃⌥Espace, flèches, Tab, Entrée, Échap.

## Moteurs

- Images : ImageIO (natif), `cwebp` pour le WebP.
- Vidéo, audio : `ffmpeg` (Homebrew).
- PDF, texte, RTF, HTML, Word, ODT : PDFKit et AppKit.
- Pages, Keynote, Numbers : pilotés par AppleScript (autorisation Automatisation demandée une fois).
- Archives : `ditto`, `zip`, `tar` (libarchive lit aussi le RAR et le 7z).

Non pris en charge : PDF vers PowerPoint ou Excel, sortie ODS.

## Construire et installer

```bash
./scripts/build-app.sh
```

Installe `~/Applications/Zeste.app` (signature locale). Chaque reconstruction change la signature :
macOS peut redemander l'autorisation Automatisation.

## Tester sans interface

```bash
.build/release/Zeste --run list fichier.png
.build/release/Zeste --run to-webp fichier.png
ZESTE_ANSWER="0:05|0:20" .build/release/Zeste --run trim video.mp4
.build/release/Zeste --run snapshot 0 roue.png fichier.png
```
