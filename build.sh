#!/bin/bash
# Compile Square, l'installe dans ~/Applications et le relance.
set -e
cd "$(dirname "$0")"
APP=build/Square.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Les textes viennent du catalogue Apple Localizable.xcstrings : texte source en français, traduction anglaise.
# Avec Xcode, le catalogue est mis à jour depuis le code à chaque compilation, puis compilé dans Resources/<langue>.lproj.
# Ces fichiers compilés sont gardés dans le dépôt : sans Xcode (outils en ligne de commande seuls), on compile avec eux.
EXTRAIRE=()
if xcrun --find xcstringstool >/dev/null 2>&1; then
  mkdir -p build/textes
  EXTRAIRE=(-emit-localized-strings -emit-localized-strings-path build/textes)
  [ -f Localizable.xcstrings ] || echo '{"sourceLanguage":"fr","strings":{},"version":"1.0"}' > Localizable.xcstrings
fi
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/Square" "${EXTRAIRE[@]}"
if [ ${#EXTRAIRE[@]} -gt 0 ]; then
  xcrun xcstringstool sync Localizable.xcstrings --stringsdata build/textes/*.stringsdata
  xcrun xcstringstool compile Localizable.xcstrings -o Resources
  if [ -f InfoPlist.xcstrings ]; then xcrun xcstringstool compile InfoPlist.xcstrings -o Resources; fi
fi
mkdir -p Resources/en.lproj Resources/fr.lproj
cp -R Resources/*.lproj "$APP/Contents/Resources/"   # anglais et français
cp Info.plist "$APP/Contents/Info.plist"
cp Icone/Square.icns "$APP/Contents/Resources/Square.icns"
# Signature stable : avec le certificat « Apple Development » du trousseau, macOS reconnaît Square d'une
# compilation à l'autre et ne redemande pas les autorisations (Accessibilité, Enregistrement de l'écran).
IDENT=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -n "$IDENT" ] && codesign --force --deep --sign "$IDENT" "$APP"; then
  echo "Signé avec : $IDENT"
else
  codesign --force --deep --sign - "$APP"
  echo "Signature jetable (pas de certificat utilisable)."
fi
if [ "$1" = "--sans-installer" ]; then exit 0; fi
mkdir -p ~/Applications
pkill -x Square || true
sleep 0.5
rm -rf ~/Applications/Square.app
cp -R "$APP" ~/Applications/
open -g ~/Applications/Square.app
echo "Square installé et lancé."
