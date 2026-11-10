#!/bin/zsh
# Builds "MA3 Dashboard.app" into ./build. Pass --install to also copy it to ~/Applications.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP="build/MA3 Dashboard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MA3Dashboard "$APP/Contents/MacOS/MA3Dashboard"

# App icon: render once from icon/render-icon.swift, then build the .icns from it.
if [[ ! -f icon/icon-1024.png || icon/render-icon.swift -nt icon/icon-1024.png ]]; then
  swift icon/render-icon.swift icon/icon-1024.png
fi
ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MA3 Dashboard</string>
  <key>CFBundleDisplayName</key><string>MA3 Dashboard</string>
  <key>CFBundleIdentifier</key><string>com.jaylen.ma3dashboard</string>
  <key>CFBundleExecutable</key><string>MA3Dashboard</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"MA3 Dashboard.app"
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/MA3 Dashboard.app"
fi
