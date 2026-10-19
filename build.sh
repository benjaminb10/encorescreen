#!/bin/zsh
# Builds build/SpareScreen.app (universal, macOS 10.15+) and build/SpareScreen.dmg.
#
# Signing, in order of preference:
#   1. "Developer ID Application" identity in the keychain → hardened runtime, then notarization + stapling
#      with the notarytool profile in $NOTARY_PROFILE (default: sparescreen-notary).
#   2. $SIGN_ID (any code signing identity, e.g. a local self-signed one) → stable permissions while developing.
#   3. Ad-hoc.
set -e
cd "${0:A:h}"
VERSION=${VERSION:-0.2}
NOTARY_PROFILE=${NOTARY_PROFILE:-sparescreen-notary}
APP=build/SpareScreen.app

rm -rf build && mkdir -p build/obj
SOURCES=(App/*.swift Shared/*.swift Main/*.swift Screen/*.swift)
xcrun swiftc -O -swift-version 5 -target x86_64-apple-macos10.15 -import-objc-header Main/VirtualDisplay.h $SOURCES -o build/obj/x86_64
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos11.0 -import-objc-header Main/VirtualDisplay.h $SOURCES -o build/obj/arm64
lipo -create build/obj/arm64 build/obj/x86_64 -output build/obj/SpareScreen

mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp build/obj/SpareScreen $APP/Contents/MacOS/SpareScreen
./fix-uuid.py $APP/Contents/MacOS/SpareScreen app.sparescreen
cp Icons/SpareScreen.icns $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SpareScreen</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>app.sparescreen</string>
<key>CFBundleName</key><string>SpareScreen</string>
<key>CFBundleDisplayName</key><string>SpareScreen</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
<key>LSMinimumSystemVersion</key><string>10.15</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Turn a Mac you already own into an extra screen.</string>
<key>NSLocalNetworkUsageDescription</key><string>SpareScreen connects your Macs on the local network to show your extra screen.</string>
<key>NSBonjourServices</key><array><string>_sparescreen._tcp</string></array>
</dict></plist>
EOF
rm -rf build/obj

DEVID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')
if [[ -n $DEVID ]]; then
  echo "Signing with $DEVID"
  codesign --force --options runtime --timestamp --sign "$DEVID" $APP
elif [[ -n $SIGN_ID ]] || security find-identity -p codesigning | grep -q "SpareScreen Local Signing"; then
  codesign --force --sign "${SIGN_ID:-SpareScreen Local Signing}" $APP
else
  codesign --force --sign - $APP
fi

# DMG: the app plus a shortcut to Applications, ready to drag.
mkdir -p build/dmg && cp -R $APP build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname "SpareScreen" -srcfolder build/dmg -ov -format UDZO build/SpareScreen.dmg
rm -rf build/dmg

if [[ -n $DEVID ]]; then
  codesign --force --timestamp --sign "$DEVID" build/SpareScreen.dmg
  xcrun notarytool submit build/SpareScreen.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/SpareScreen.dmg
  xcrun stapler staple $APP
fi
echo "OK: $APP and build/SpareScreen.dmg"
