#!/bin/bash
# Pocket Turbo Kingdom — iOS 12 客户端构建脚本
#
# 在装有 Xcode 的构建机（Mac mini / ruok）上运行，不需要 Xcode 工程文件：
# 直接 xcrun clang 编译 ObjC 源码 → ldid 假签名 → dpkg-deb 打成 .deb → Sileo 安装。
# 与 ~/LLMChat-iOS12/build.sh 同一套约定（.deb 必须 xz 压缩，设备上的 dpkg 解不了 gzip）。
#
# 用法：
#   ./build.sh
#   PTK_ENTRY=tools/hello.m PTK_SOURCES=tools/hello.m \
#     APP_NAME=PocketTurboHello APP_BUNDLE_ID=com.zhangzhangco.ptkhello ./build.sh
#
# 可用环境变量覆盖：
#   PTK_ENTRY             入口 .m（默认 client/main.m）
#   PTK_SOURCES           源文件列表，空格分隔（默认 find client -name '*.m'）
#   APP_NAME              可执行文件名 / .app 名（默认 PocketTurboKingdom）
#   APP_BUNDLE_ID         CFBundleIdentifier（默认 com.zhangzhangco.pocketturbo）
#   APP_DISPLAY_NAME      桌面显示名（默认 口袋赛车王国）
#   APP_VERSION           版本号（默认 0.1.0）
#   PKG_ID                .deb 包名（默认同 APP_BUNDLE_ID）
#   PTK_SKIP_TESTS=1      跳过单元测试门槛（默认会先跑 tests/run_tests.sh）
set -euo pipefail
cd "$(dirname "$0")"

# Xcode 装在 /Applications/Xcode.app，但 xcode-select 指向 CommandLineTools，
# 所以必须显式指定 DEVELOPER_DIR，否则 xcrun 找不到 iphoneos SDK。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH=/opt/homebrew/bin:$PATH   # ldid / dpkg-deb 都在 Homebrew 里

APP="${APP_NAME:-PocketTurboKingdom}"
BUNDLE="${APP_BUNDLE_ID:-com.zhangzhangco.pocketturbo}"
PKG="${PKG_ID:-$BUNDLE}"
VERSION="${APP_VERSION:-0.1.0}"
DISPLAY_NAME="${APP_DISPLAY_NAME:-口袋赛车王国}"
ENTRY="${PTK_ENTRY:-client/main.m}"

echo "==> 应用: $APP ($DISPLAY_NAME) v$VERSION  包名: $PKG"
echo "==> DEVELOPER_DIR: $DEVELOPER_DIR"
[ -d "$DEVELOPER_DIR" ] || { echo "错误：找不到 $DEVELOPER_DIR（本机没有完整 Xcode？）" >&2; exit 1; }

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "==> SDK: $SDK"
[ -d "$SDK" ] || { echo "错误：xcrun 没给出 iphoneos SDK 路径" >&2; exit 1; }

[ -f "$ENTRY" ] || { echo "错误：入口文件不存在：$ENTRY" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 源文件：默认收 client/ 下所有 .m（含子目录），客户端变大也不用改脚本
# ---------------------------------------------------------------------------
SOURCES=()
if [ -n "${PTK_SOURCES:-}" ]; then
  read -r -a SOURCES <<< "$PTK_SOURCES"
elif [ -d client ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && SOURCES+=("$f")
  done < <(find client -name '*.m' | sort)
fi

# 入口必须出现在源文件列表里（PTK_SOURCES 覆盖时也不能落下）
entry_in_list=0
for f in ${SOURCES[@]+"${SOURCES[@]}"}; do
  [ "$f" = "$ENTRY" ] && entry_in_list=1
done
if [ "$entry_in_list" = 0 ]; then
  SOURCES=("$ENTRY" ${SOURCES[@]+"${SOURCES[@]}"})
fi
[ ${#SOURCES[@]} -gt 0 ] || { echo "错误：没有找到任何 .m 源文件" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 头文件搜索路径：client/ 下所有子目录都加 -I，客户端可以 #import "PTKTrackData.h"
# ---------------------------------------------------------------------------
INCS=()
add_inc() {
  if [ -d "$1" ]; then
    for existing in ${INCS[@]+"${INCS[@]}"}; do
      [ "$existing" = "-I$1" ] && return
    done
    INCS+=("-I$1")
  fi
}
add_inc .
add_inc "$(dirname "$ENTRY")"
if [ -d client ]; then
  while IFS= read -r d; do add_inc "$d"; done < <(find client -type d | sort)
fi

rm -rf build dist
mkdir -p "build/$APP.app" dist

echo "==> 源文件 (${#SOURCES[@]}):"
printf '      %s\n' "${SOURCES[@]}"
echo "==> 头文件路径:"
printf '      %s\n' "${INCS[@]}"

# ---------------------------------------------------------------------------
# 测试门槛：帧编解码 / 协议解析这些底层回归必须在打包前挡住
# （与 LLMChat-iOS12 的约定一致；用 PTK_SKIP_TESTS=1 可临时跳过）
# ---------------------------------------------------------------------------
if [ "${PTK_SKIP_TESTS:-0}" = "1" ]; then
  echo "==> 已跳过单元测试（PTK_SKIP_TESTS=1）"
elif [ -x tests/run_tests.sh ]; then
  echo "==> 单元测试门槛: tests/run_tests.sh"
  if ! ./tests/run_tests.sh; then
    echo "单元测试未通过，停止打包（要临时跳过：PTK_SKIP_TESTS=1）" >&2
    exit 1
  fi
else
  echo "==> 未找到 tests/run_tests.sh，跳过测试门槛"
fi

# ---------------------------------------------------------------------------
# 编译
# ---------------------------------------------------------------------------
CLANG=(
  xcrun --sdk iphoneos clang
  -arch arm64 -isysroot "$SDK" -miphoneos-version-min=12.0
  -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
)
FRAMEWORKS=(
  -framework UIKit -framework Foundation -framework SceneKit -framework QuartzCore
  -framework CoreGraphics -framework CoreText -framework ImageIO
)
APP_BIN="build/$APP.app/$APP"

echo "==> 编译命令:"
echo "      ${CLANG[*]} ${INCS[*]} ${SOURCES[*]} ${FRAMEWORKS[*]} -o $APP_BIN"
"${CLANG[@]}" ${INCS[@]+"${INCS[@]}"} ${SOURCES[@]+"${SOURCES[@]}"} \
  ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"} -o "$APP_BIN"

# ---------------------------------------------------------------------------
# Info.plist（python3 plistlib 生成，不手写 XML）
# ---------------------------------------------------------------------------
python3 - "$APP" "$BUNDLE" "$VERSION" "$DISPLAY_NAME" <<'PY'
import plistlib, sys
from pathlib import Path

app, bundle, version, display = sys.argv[1:5]
ICONS = ['Icon-20', 'Icon-29', 'Icon-40', 'Icon-60', 'Icon-76', 'Icon-83.5', 'Icon-1024']
plist = {
    'CFBundleIdentifier': bundle,
    'CFBundleExecutable': app,
    'CFBundleName': app,
    'CFBundleDisplayName': display,
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version,
    'CFBundleVersion': version,
    'CFBundleSupportedPlatforms': ['iPhoneOS'],
    'MinimumOSVersion': '12.0',
    'UIDeviceFamily': [2],                       # 只装 iPad
    # 只允许横屏：游戏是全屏横屏驾驶视角
    'UISupportedInterfaceOrientations': [
        'UIInterfaceOrientationLandscapeLeft',
        'UIInterfaceOrientationLandscapeRight',
    ],
    'UISupportedInterfaceOrientations~ipad': [
        'UIInterfaceOrientationLandscapeLeft',
        'UIInterfaceOrientationLandscapeRight',
    ],
    'UIRequiresFullScreen': True,
    'UIStatusBarHidden': True,
    'UIViewControllerBasedStatusBarAppearance': False,
    'UILaunchImages': [],
    # 连局域网 ws://192.168.x.x:5173 —— 明文 + 本地网络都要放行
    'NSAppTransportSecurity': {
        'NSAllowsArbitraryLoads': True,
        'NSAllowsLocalNetworking': True,
    },
    'NSLocalNetworkUsageDescription': '连接局域网内的 Pocket Turbo Kingdom 比赛服务器。',
    'CFBundleIconFiles': ICONS,
    'CFBundleIcons': {
        'CFBundlePrimaryIcon': {
            'CFBundleIconFiles': ICONS,
            'UIPrerenderedIcon': False,
        },
    },
    'CFBundleIcons~ipad': {
        'CFBundlePrimaryIcon': {
            'CFBundleIconFiles': ICONS,
            'UIPrerenderedIcon': False,
        },
    },
}
Path(f'build/{app}.app/Info.plist').write_bytes(plistlib.dumps(plist))
print('==> Info.plist 写入完毕 (MinimumOSVersion 12.0 / UIDeviceFamily [2] / 仅横屏)')
PY

# ---------------------------------------------------------------------------
# 图标
# ---------------------------------------------------------------------------
python3 make_icon.py "build/$APP.app"

# ---------------------------------------------------------------------------
# 几何资产：client 用 [[NSBundle mainBundle] pathForResource:@"track" ofType:@"ptkgeo"]
# 读取，所以 .ptkgeo 必须放在 .app 根目录（不是子目录）
# ---------------------------------------------------------------------------
shopt -s nullglob
geos=(assets/*.ptkgeo)
shopt -u nullglob
if [ ${#geos[@]} -gt 0 ]; then
  cp -f "${geos[@]}" "build/$APP.app/"
  echo "==> 拷入资源: ${geos[*]}"
else
  echo "==> 警告: 没有 assets/*.ptkgeo（目录缺失或不含资产），跳过。App 内将读不到 track.ptkgeo"
fi

# ---------------------------------------------------------------------------
# 假签名（iOS 12 越狱设备只需要 ldid ad-hoc 签名）
# ---------------------------------------------------------------------------
ldid -S "$APP_BIN"
echo "==> ldid -S 假签名完成"

echo "==> 二进制信息"
file "$APP_BIN" | sed 's/^/      /'
echo "      --- Mach-O 版本信息 (arm64 + minos) ---"
otool -l "$APP_BIN" | awk '
  /LC_VERSION_MIN_IPHONEOS|LC_BUILD_VERSION/ { p=1; print "      "$0; next }
  p && /^ *(cmdsize|platform|minos|sdk|ntools|tool|version) /  { print "      "$0; next }
  p { p=0 }
'
echo "      --- CPU 架构 ---"
lipo -info "$APP_BIN" | sed 's/^/      /'
echo "      --- 代码签名 ---"
if otool -l "$APP_BIN" | grep -q LC_CODE_SIGNATURE; then
  echo "      LC_CODE_SIGNATURE 存在"
else
  echo "      警告: 没找到 LC_CODE_SIGNATURE！" >&2
fi
if ldid -e "$APP_BIN" >/dev/null 2>&1; then
  echo "      ldid -e ok（无 entitlements，属正常）"
else
  echo "      ldid -e 返回非 0（无 entitlements，属正常）"
fi
ldid -S "$APP_BIN" && echo "      ldid -S 二次校验 ok"

# ---------------------------------------------------------------------------
# 打 .deb
# ---------------------------------------------------------------------------
mkdir -p build/package/Applications build/package/DEBIAN
cp -R "build/$APP.app" build/package/Applications/
chmod 755 "build/package/Applications/$APP.app/$APP"

INSTALLED_KB=$(du -sk "build/package/Applications/$APP.app" | awk '{print $1}')

cat > build/package/DEBIAN/control <<CONTROL
Package: $PKG
Name: $DISPLAY_NAME
Version: $VERSION
Architecture: iphoneos-arm
Maintainer: zhangzhangco
Section: Applications
Installed-Size: $INSTALLED_KB
Description: Pocket Turbo Kingdom —— iPad mini 2 (iOS 12) 原生赛车客户端。ObjC + SceneKit 薄客户端，局域网 WebSocket 连服务器，渲染 20Hz snapshot。
CONTROL

# uicache 让 SpringBoard 立刻刷新图标；不同越狱版本参数不同，两种都试
cat > build/package/DEBIAN/postinst <<POSTINST
#!/bin/sh
set -e
if command -v uicache >/dev/null 2>&1; then
  uicache -p /Applications/$APP.app || uicache -a || true
fi
exit 0
POSTINST
chmod 755 build/package/DEBIAN/postinst

DEB="dist/${PKG}_${VERSION}_iphoneos-arm.deb"
# -Zxz：设备上的 dpkg 不支持 gzip 压缩的 data.tar，必须 xz
dpkg-deb --build --root-owner-group -Zxz build/package "$DEB"

echo
echo "=================== 构建完成 ==================="
ls -lh "$DEB"
echo
echo "--- dpkg-deb -I ---"
dpkg-deb -I "$DEB"
echo
echo "--- dpkg-deb -c（成员列表）---"
dpkg-deb -c "$DEB"
echo
echo "DEB 路径: $(pwd)/$DEB"
echo "安装: 见 INSTALL.md"
