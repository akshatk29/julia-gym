#!/bin/bash
# Assemble "Julia Gym.app" in the project root. Re-runnable.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Julia Gym.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The launcher, with the build-time project path baked in as a fallback for
# the case where someone moves the app out of the project folder.
sed "s|__PROJECT_ROOT__|$ROOT|g" "$ROOT/build/launcher.sh" > "$APP/Contents/MacOS/JuliaGym"
chmod +x "$APP/Contents/MacOS/JuliaGym"

cp "$ROOT/build/JuliaGym.icns" "$APP/Contents/Resources/JuliaGym.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Julia Gym</string>
    <key>CFBundleDisplayName</key>       <string>Julia Gym</string>
    <key>CFBundleIdentifier</key>        <string>local.juliagym.app</string>
    <key>CFBundleVersion</key>           <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>JuliaGym</string>
    <key>CFBundleIconFile</key>          <string>JuliaGym</string>
    <key>LSMinimumSystemVersion</key>    <string>10.13</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Not a background agent: we want the Dock icon, so quitting stops the
         server rather than leaving it running invisibly. -->
    <key>LSUIElement</key>               <false/>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

# Ad-hoc sign so the bundle has a stable identity rather than none at all.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

# Nudge Finder to pick up the new icon rather than a cached one.
touch "$APP"
echo "Built: $APP"
