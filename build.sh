#!/bin/bash
# Compile Square, l'installe dans ~/Applications et le relance.
set -e
cd "$(dirname "$0")"
APP=build/Square.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/Square"
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
