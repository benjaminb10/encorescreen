#!/bin/zsh
# Builds both apps into build/:
#   SpareScreen.app           (main Mac, macOS 14+, Apple Silicon and Intel)
#   SpareScreen Receiver.app  (old Mac, macOS 10.15+, Intel and Apple Silicon)
set -e
cd "${0:A:h}"
rm -rf build && mkdir -p build/obj

bundle() { # $1 name, $2 binary, $3 bundle id, $4 minimum macOS, $5 LSUIElement (true/false), $6 executable name
  local app="build/$1.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$2" "$app/Contents/MacOS/$6"
  mkdir -p "$app/Contents/Resources"
  cp "Icons/$6.icns" "$app/Contents/Resources/AppIcon.icns"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$6</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>$3</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundleDisplayName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>$4</string>
<key>LSUIElement</key><$5/>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>SpareScreen connects your Macs on the local network to show the picture.</string>
<key>NSBonjourServices</key><array><string>_sparescreen._tcp</string></array>
</dict></plist>
EOF
  codesign --force --sign "${SIGN_ID:-B73589F7A6F3391AF765FAAEE6C1A6F6CD2A8847}" "$app" 2>/dev/null || codesign --force --sign - "$app"
}

# Sender: universal binary
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target $arch-apple-macos14.0 -import-objc-header Sender/VirtualDisplay.h \
    Sender/*.swift -o build/obj/sender-$arch
done
lipo -create build/obj/sender-arm64 build/obj/sender-x86_64 -output build/obj/sender

# Receiver: universal binary, Catalina compatible
xcrun swiftc -O -swift-version 5 -target x86_64-apple-macos10.15 Receiver/Receiver.swift -o build/obj/receiver-x86_64
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos11.0 Receiver/Receiver.swift -o build/obj/receiver-arm64
lipo -create build/obj/receiver-arm64 build/obj/receiver-x86_64 -output build/obj/receiver

bundle "SpareScreen" build/obj/sender app.sparescreen.sender 14.0 true SpareScreen
bundle "SpareScreen Receiver" build/obj/receiver app.sparescreen.receiver 10.15 false SpareScreenReceiver
rm -rf build/obj
echo "OK: $(ls build | tr '\n' ' ')"
