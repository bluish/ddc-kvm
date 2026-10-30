#!/bin/sh
# Build kvmctl + Desk.app and install the app to ~/Applications (opens at login).
set -e
cd "$(dirname "$0")"

swiftc -O -o kvmctl KVMCore.swift main.swift
swiftc -O -parse-as-library -o Desk KVMCore.swift Model.swift Kit.swift DeskApp.swift

app="$HOME/Applications/Desk.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp Desk "$app/Contents/MacOS/Desk"
set_dir=$(mktemp -d)/AppIcon.iconset
mkdir -p "$set_dir" "$app/Contents/Resources"
for size in 16 32 128 256 512; do
  sips -z $size $size AppIcon.png --out "$set_dir/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) AppIcon.png --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.bluish.kvmbar</string>
  <key>CFBundleName</key><string>Desk</string>
  <key>CFBundleExecutable</key><string>Desk</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <!-- The kvm relay is plain HTTP (meant for a private network such as a tailnet) -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
EOF
# Ad-hoc signature. The default designated requirement is the binary's cdhash,
# which changes on every build and silently voids the Input Monitoring grant
# (System Settings keeps showing it as allowed). Pin it to the bundle id instead.
codesign --force --sign - -r='designated => identifier "io.github.bluish.kvmbar"' "$app"

agent="$HOME/Library/LaunchAgents/io.github.bluish.kvmbar.plist"
cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.bluish.kvmbar</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$app</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
echo "built: $app"
