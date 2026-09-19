#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DEVICE=${PTK_SIMULATOR:?Set PTK_SIMULATOR to an available iPad simulator UUID}
OUT=$(mktemp -d /tmp/ptk-ui.XXXXXX)
APP="$OUT/PTKUITests.app"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang -arch arm64 -isysroot "$SDK" -mios-simulator-version-min=15.0 \
  -fobjc-arc -Iclient/UI -Iclient/Net -Iclient/Render \
  tests/ui_test.m client/UI/*.m client/Net/PTKProtocol.m client/Render/PTKTrackData.m \
  -framework UIKit -framework Foundation -framework SceneKit -framework CoreGraphics -framework QuartzCore -framework CoreText -framework ImageIO -o "$APP/PTKUITests"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.zhangzhangco.ptkuitests</string>
<key>CFBundleExecutable</key><string>PTKUITests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>UIDeviceFamily</key><array><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"
DATA=$(xcrun simctl get_app_container "$DEVICE" com.zhangzhangco.ptkuitests data)
rm -f "$DATA/Documents/result.txt"
xcrun simctl launch --terminate-running-process "$DEVICE" com.zhangzhangco.ptkuitests
for ((i=0; i<30; i++)); do
  if [ -f "$DATA/Documents/result.txt" ]; then
    cat "$DATA/Documents/result.txt"
    echo
    echo "Screenshots: $DATA/Documents"
    grep -q '^PASS:' "$DATA/Documents/result.txt"
    exit $?
  fi
  sleep 1
done
echo 'FAIL: simulator timed out' >&2
exit 1
