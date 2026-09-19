# Pocket Turbo Kingdom · iPad mini 2 打包与安装指南

目标设备：**iPad4,4 / iPad mini 2 / A7 / 1GB / 1024×768@2x / iOS 12.5.8**（Amethyst 越狱，已装 Sileo + Zebra）。

本机（MacBook Pro，**只有 CommandLineTools，不能编 iOS**）不装 Xcode；编译在构建机 **mini**（hostname `ruOK`，Tailscale `100.65.190.37`，Xcode 26.5）上做：

```
本机 ios/PocketTurboKingdom/  ──rsync──▶  mini:~/PocketTurboKingdom/
                                              ./build.sh
                                              xcrun clang -arch arm64 -miphoneos-version-min=12.0
                                              ldid -S 假签名
                                              dpkg-deb -Zxz → .deb
本机 ios/PocketTurboKingdom/dist/*.deb  ◀──rsync──  mini:~/PocketTurboKingdom/dist/*.deb
        │
        ├─(推荐) ./dev.sh publish → 构建机上的 APT 源 → iPad Sileo 安装
        └─(备用) 传到 iPad → dpkg -i / Filza 安装
```

---

## 0. 前置事实（本次实测确认）

| 项目 | 实际情况 |
| --- | --- |
| 构建机 | `ssh mini` 免密可用；`hostname` = `ruOK` |
| Xcode | `/Applications/Xcode.app`，SDK = `iPhoneOS26.5.sdk`；`xcode-select -p` 指向 **CommandLineTools**，所以脚本里必须显式 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |
| 打包工具 | `/opt/homebrew/bin/ldid`（2.1.5）、`/opt/homebrew/bin/dpkg-deb`（dpkg 1.23.11） |
| 本机 | 只有 CommandLineTools；`idevicesyslog / ideviceinfo / ideviceinstaller / iproxy`（libimobiledevice 1.4.0）**已装** |
| iPad | UDID `4932b1f996023ee6482849920a94d7ce3b1e52d0`；越狱已成功，Sileo 可用 |
| APT 源 | 构建机上**确实已有**一个现成可用的源（位置不是 `~/apt-repo`，见 §2A），线上地址 `https://zhangzhangco.github.io/ipad-mini2-repo/` |

---

## 1. 重新打包

几何资产（`assets/*.ptkgeo`，约 5 MB）是**生成物**，没有进 git。首次打包前先生成一次：

```bash
npm install                                   # 仓库根目录，导出器要用 three/rapier
node ios/export/export-scene.mjs              # three.js 场景 → ios/PocketTurboKingdom/assets/*.ptkgeo
# 需要瘦身时：node ios/export/export-scene.mjs --density 0.45
```

```bash
cd ios/PocketTurboKingdom

./dev.sh              # rsync 源码 → 构建机上编译打包 → 把 .deb 取回 dist/
./dev.sh publish      # 上面全部做完后再发布到 APT 源（见 §2A）
```

- 构建机可用 `MINI=user@host ./dev.sh` 覆盖（默认 `mini`）。
- `dev.sh` 会把下面这些变量 export 到构建机上的 `build.sh`：`PTK_ENTRY`、`PTK_SOURCES`、`APP_NAME`、`APP_BUNDLE_ID`、`APP_DISPLAY_NAME`、`APP_VERSION`、`PKG_ID`。
- 只想先验证链路（编译 `tools/hello.m` 这个最小 App，不动 `client/`）：

```bash
PTK_ENTRY=tools/hello.m PTK_SOURCES=tools/hello.m \
  APP_NAME=PocketTurboHello APP_BUNDLE_ID=com.zhangzhangco.ptkhello \
  APP_DISPLAY_NAME="Pocket Turbo Hello" ./dev.sh
```

- 直接在构建机上跑（调试编译错误时更快，`client/` 已经在构建机上）：

```bash
ssh mini 'export PATH=/opt/homebrew/bin:$PATH; cd ~/PocketTurboKingdom && ./build.sh'
```

产物：`ios/PocketTurboKingdom/dist/<包名>_<版本>_iphoneos-arm.deb`
（默认包名 `com.zhangzhangco.pocketturbo`，默认 App 名 `PocketTurboKingdom`）

`build.sh` 的行为要点：

- 源码用 **glob 收集**：默认 `find client -name '*.m'`（含子目录），入口 `client/main.m`；客户端变大不用改脚本。
- 头文件路径：`. ` + `client/` 下**所有子目录**都进 `-I`，所以 `#import "PTKTrackData.h"` 这种写法能直接编。
- 把 `assets/*.ptkgeo` 拷到 **`.app` 根目录**（`[[NSBundle mainBundle] pathForResource:@"track" ofType:@"ptkgeo"]` 才能读到）；`assets/` 不存在时只警告不报错。
- `Info.plist` 用 python3 `plistlib` 生成：`MinimumOSVersion 12.0`、`UIDeviceFamily [2]`、只允许横屏、`UIRequiresFullScreen`、`NSAllowsArbitraryLoads + NSAllowsLocalNetworking`（连局域网 `ws://192.168.x.x:5173`）。
- `ldid -S` 假签名 → `dpkg-deb --build --root-owner-group -Zxz`（**必须 xz**）→ postinst 里 `uicache -p /Applications/<App>.app || uicache -a`。
- 结尾打印 `.deb` 路径、`dpkg-deb -I` 摘要、`dpkg-deb -c` 成员列表。

---

## 2. 装到 iPad

### 2A（推荐）走 APT 源 + Sileo —— 构建机上已有现成源

`ls ~/apt-repo` 在构建机上是**不存在**的；实际存在的源是另一个路径（本次查实）：

| 项目 | 实际值 |
| --- | --- |
| 仓库本地克隆 | `mini:~/ipad-second-monitor/repo` |
| git remote | `git@github.com:zhangzhangco/ipad-mini2-repo.git` |
| 索引/签名脚本 | `mini:~/ipad-second-monitor/publish-repo.py` |
| 线上地址（Sileo 里填这个） | **`https://zhangzhangco.github.io/ipad-mini2-repo/`** |
| 已收录的包 | `com.example.legacypaddisplay`、`com.zhangzhangco.llmchat`、`com.zhangzhangco.minigames`、`com.zhangzhangco.ptkhello` |

`dev.sh` 的 publish 会自动探测 `~/apt-repo` → `~/ipad-second-monitor/repo`，找到就用；找不到只打印提示、**不会**新建远端仓库。要显式指定：

```bash
MINI=mini APT_REPO=/Users/zhangxin/ipad-second-monitor/repo ./dev.sh publish
```

> 注意：经 `ssh` 传过去的 `~/...` 一般不会展开，脚本里虽然会补一下，但**用绝对路径最稳**。

**iPad 上的操作：**

1. Sileo → 「源」→ 右上角编辑 → 添加源 → 填 `https://zhangzhangco.github.io/ipad-mini2-repo/`
2. 回到「源」下拉刷新（GitHub Pages 推送后一般 1 分钟内生效）
3. 搜索 `Pocket Turbo` → 安装 → 装完桌面出现图标（postinst 已经跑过 `uicache`）

> 前提是 iPad 能访问 GitHub。办公室 Wi-Fi 若访问不了，走 2B / 2C。

### 2B 直接把 `.deb` 传进 iPad + `dpkg -i`（iPad 上有 OpenSSH 时）

```bash
# 1) iPad 的 IP：设置 → 无线局域网 → 点当前网络旁的 ⓘ → IP 地址
# 2) 传包（默认 root 密码 alpine）
scp ios/PocketTurboKingdom/dist/com.zhangzhangco.ptkhello_0.1.0_iphoneos-arm.deb \
    root@<iPad-IP>:/var/mobile/

# 3) 安装（postinst 会自动 uicache；再手动跑一次也无害）
ssh root@<iPad-IP>
dpkg -i /var/mobile/com.zhangzhangco.ptkhello_0.1.0_iphoneos-arm.deb
uicache -a
```

- iPad 上没有 OpenSSH：Sileo 里搜 `OpenSSH` 装上（越狱源里都有），或直接用 2C。
- 一次装多个包：`dpkg -i /var/mobile/*.deb`；装完不显示图标就 `uicache -a` 或重启 SpringBoard。

### 2C 不用 ssh：Safari 下载 + Filza 安装

1. 本机起个临时的局域网 HTTP 服务：
   ```bash
   cd ios/PocketTurboKingdom/dist && python3 -m http.server 8000
   ipconfig getifaddr en0        # 本机 IP，例如 192.168.102.55
   ```
2. iPad Safari 打开 `http://<本机IP>:8000/` → 点 `.deb` 下载（或 AirDrop 传到 iPad）。
3. 用 **Filza** 打开该 `.deb` → 点它 → `Install`（Filza 内置 dpkg 安装；也可以「分享 → 用 Sileo 打开」）。
4. 装完若桌面没图标：Filza 的命令行里 `uicache -a`，或重启一下。

### 2D 用不了的路径（避免白试）

- `ideviceinstaller` / `ios-deploy` / Xcode 的 `devicectl`：只能装 `.ipa`（应用签名），**装不了 `.deb`**；本机也没有 Xcode。
- 免费开发者账号签名：只有 7 天有效期，`.deb` 装进 `/Applications` 才是真正的系统级安装，不受此限。

---

## 3. 卸载

```bash
ssh root@<iPad-IP> 'dpkg -r com.zhangzhangco.ptkhello && uicache -a'
# 或者：dpkg -P <包名>（连配置文件一起删）
```

Sileo：已安装 → 找到该 App → 卸载。

把包从 APT 源里彻底下架（在构建机上）：

```bash
ssh mini
rm ~/ipad-second-monitor/repo/debs/com.zhangzhangco.ptkhello_0.1.0_iphoneos-arm.deb
python3 ~/ipad-second-monitor/publish-repo.py
cd ~/ipad-second-monitor/repo && git add -A && git commit -m "Remove ptkhello" && git push
```

---

## 4. 看日志 / 排错

**本机（iPad 用数据线连着，libimobiledevice 已装）**

```bash
idevicesyslog -u 4932b1f996023ee6482849920a94d7ce3b1e52d0 -m PTKHello
#   -m 只输出匹配行；hello.m 启动时会打 [PTKHello] launched on ...
idevicesyslog -u <UDID> -o /tmp/ipad.log      # 落盘
idevice_id -l                                  # 看设备是否被识别
```

**无线（iPad 与 Mac 同网段、之前配对过 Wi-Fi 同步）**

```bash
idevicesyslog -n -m PTKHello
```

**设备上（装了 `socat` 的话）**

```bash
socat - UNIX-CONNECT:/var/run/lockdown/syslog.sock | grep -i ptk
tail -f /var/log/syslog          # 有些越狱环境开了 syslogd
```

**崩溃日志**

- 设备：`/var/mobile/Library/Logs/CrashReporter/`
- 本机（同步过）：`~/Library/Logs/CrashReporter/MobileDevice/<iPad 名字>/`

**装上了但打不开 / 闪退，按顺序查**

```bash
ssh root@<iPad-IP>
ls -l /Applications/PocketTurboHello.app            # 二进制、Info.plist、track.ptkgeo 是否都在
ldid -e /Applications/PocketTurboHello.app/PocketTurboHello   # 能读出内容 = 签名 blob 在
uicache -a                                          # 刷图标
```

再用 `idevicesyslog` 看崩溃前最后几行；如果是「用了 iOS 13+ 才有的符号」导致的崩溃，见 §5 第 1 条。

---

## 5. 已知坑（本次实测踩到的）

1. **Xcode 26.5 SDK 编 iOS 12 能过，但 SDK 里有些 API 标了更高的可用版本。**
   编译 hello.m 零警告；但 `client/Render/PTKTrackData.m` 出现了：
   - `CGColorCreateGenericRGB` → `-Wunguarded-availability-new`（头文件标 iOS 13.0+）。这个符号在 iOS 12 上是**弱链接 NULL**，真机调用会崩。改用 `CGColorCreate(colorSpace, comps)` 或直接拿 `[UIColor ...].CGColor`。
   - `CGBitmapContextCreate(..., kCGImageAlphaPremultipliedLast)` → `-Wimplicit-enum-enum-cast`，需要显式 `(CGBitmapInfo)kCGImageAlphaPremultipliedLast`。
   结论：`-Wextra` 下这两个警告要当成错误处理，`CGColor*Generic*` / `CGColorCreateSRGB`（iOS 13+）一律别用。
2. **`.deb` 必须 xz 压缩**（`dpkg-deb -Zxz`）。设备上的 dpkg 解不了 gzip 的 `data.tar`，装了会报解压失败。
3. **必须 `ldid -S`**：iOS 12 越狱设备要 ad-hoc 假签名才能启动；不用开发者证书。
4. **Info.plist**：`MinimumOSVersion 12.0` + `UIDeviceFamily [2]` 不能少；只留横屏要同时写 `UISupportedInterfaceOrientations`（和 `~ipad` 那份）；没有 launch storyboard 时 `UIRequiresFullScreen=true` + `UILaunchImages=[]` 才能全屏，不然会被 letterbox 或进兼容模式。
5. **SceneKit 链接**：除了 `-framework SceneKit`，还要 `QuartzCore`（`SCNView` 走 CoreAnimation）、`CoreGraphics`、`CoreText`（文字几何）、`ImageIO`（`CGImageSource*` 读贴图）。iOS 12 上没有 iOS 13+ 的 `SCNMaterial.clearCoat*` 之类属性，用了同样是弱符号。
6. **构建机 `xcode-select -p` 指向 CommandLineTools**：任何 `xcrun` 之前都要 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，否则找不到 iphoneos SDK。`build.sh` 已经在开头写死。
7. **`dev.sh` 透传变量必须 `export VAR=value;`**。写成 `VAR=value cd ~/dir && ./build.sh` 时，赋值只作用于 `cd`，`./build.sh` 根本看不到（这个坑已踩，脚本里注释标了）。
8. **`client/` 下所有子目录都要 `-I`**，否则跨目录 `#import "PTKTrackData.h"` 直接编译失败。
9. `rsync -a --delete --exclude dist` 时远端 `dist/` 受排除保护不会被删，所以取回 `.deb` 前它一直都在；本地 `dist/` 用 `--include='*.deb' --exclude='*'` 只拉 `.deb`，历史版本保留便于回滚。
10. 本机 `python3 -m py_compile` 会往 `~/Library/Caches/com.apple.python/...` 写缓存，在本沙箱里会被拒绝（`Operation not permitted`）——与脚本本身无关。

---

## 6. 链路验证记录（2026-09-19，Hello World 端到端实测）

用 `tools/hello.m` 走了一遍完整链路（`client/` 一行没动）：

```
SDK:            /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk
编译:           xcrun --sdk iphoneos clang -arch arm64 -isysroot <SDK> -miphoneos-version-min=12.0
                -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
                -I. -Itools -Iclient -Iclient/Net -Iclient/Render -Iclient/Support -Iclient/UI
                tools/hello.m -framework UIKit -framework Foundation -framework SceneKit
                -framework QuartzCore -framework CoreGraphics -framework CoreText -framework ImageIO
                -o build/PocketTurboHello.app/PocketTurboHello
结果:           0 error / 0 warning
二进制:         Mach-O 64-bit executable arm64
                LC_BUILD_VERSION: platform IOS, minos 12.0, sdk 26.5, tool LD 1267.0
                LC_CODE_SIGNATURE datasize 1488（ldid -e 退出码 0，ldid -S 二次签名退出码 0）
.deb:           com.zhangzhangco.ptkhello_0.1.0_iphoneos-arm.deb = 584656 bytes (571K)
                归档成员：debian-binary / control.tar.xz / data.tar.xz
                内含 Applications/PocketTurboHello.app/{PocketTurboHello, Info.plist,
                track.ptkgeo(4955653), arena.ptkgeo(70246), Icon-*.png ×15}
本机 dev.sh:    rsync → 远程 build.sh → rsync 回 ios/PocketTurboKingdom/dist/ ✅
publish:        已推到 https://zhangzhangco.github.io/ipad-mini2-repo/（Packages 里能看到
                com.zhangzhangco.ptkhello；deb 的 HTTP 200）✅
```

**还没做的一步：** iPad 当前不在线（USB 没插、`172.20.10.2:22` 不通），所以最后「在 iPad 上点安装 → 启动看到黑底黄字 + `track.ptkgeo FOUND`」需要用户手工完成：

1. iPad 打开 Sileo → 源 → 添加 `https://zhangzhangco.github.io/ipad-mini2-repo/` → 刷新 → 搜 `Pocket Turbo Hello` → 安装
2. 桌面上点开 `Pocket Turbo Hello`，屏幕应显示 `POCKET TURBO KINGDOM` + `iOS 12.5.8 · iPad4,4`，下面两行绿色的 `track.ptkgeo ✓ FOUND`、`arena.ptkgeo ✓ FOUND`（含路径与字节数）
3. 若显示红色 `✗ MISSING`，说明 `.app` 里没带上 `.ptkgeo`，重跑 `./dev.sh` 并检查构建机上 `assets/` 是否有文件

---

## 7. 文件清单

| 文件 | 作用 |
| --- | --- |
| `build.sh` | 在构建机上编译（clang arm64 / iOS 12）+ `ldid -S` + 生成 `Info.plist` / 图标 + 打 xz `.deb`；结尾打印 deb 路径、`dpkg-deb -I`、`dpkg-deb -c` |
| `dev.sh` | 本机驱动：rsync 到 `mini:~/PocketTurboKingdom/` → 远程 `build.sh` → 取回 `dist/*.deb`；`./dev.sh publish` 再发布到 APT 源 |
| `make_icon.py` | 纯标准库生成全套 App 图标（深青底 + 亮黄卡通赛车 + 速度线，含 1024） |
| `tools/hello.m` | 链路验证用最小 UIKit App：横屏黑底、`POCKET TURBO KINGDOM / iOS <版本>`、显示 `track.ptkgeo` 是否找到及路径/大小 |
| `INSTALL.md` | 本文档 |

## 8. iPad 界面修复版 0.1.1

构建：`APP_VERSION=0.1.1 ./dev.sh`。安装包位于
`dist/com.zhangzhangco.pocketturbo_0.1.1_iphoneos-arm.deb`，仍使用上述越狱设备安装流程。

- 操作区与速度/道具 HUD 分离，并按照安全区域布局；大厅不显示比赛 HUD。
- 摇杆固定在左下方，初始化居中，支持 12% 中心死区；尺寸变化、离开比赛、切后台会释放输入。
- 选车行保留明确高度；大厅可滚动，键盘出现后输入框可见；房间码初始为空并提高占位文字对比度。

UIKit 回归测试在有 Xcode 的构建机运行：

```bash
PTK_SIMULATOR=<iPad模拟器UUID> bash tests/run_ui_tests.sh
```

已在 iOS 26.5 模拟器检查 1024×768、1133×744、1366×1024 三种视图尺寸，
覆盖按钮边界/重叠、左右转向、死区、隐藏后输入归零、尺寸变化与键盘避让。
测试生成 `result.txt` 和界面截图，脚本输出其路径。arm64 / iOS 12 最低部署版本构建通过；
这些检查不替代 iOS 12 真机多指操作和驾驶手感验收。


---

## 8. 单人模式（1 人 + 3 名服务端 AI）

服务端支持「单人发车」：房主一个人点开始，服务器会补 3 个 `bot: true` 的电脑车手，物理与 AI 全在 Mac 侧算，iPad 仍然只是薄客户端。

- 协议：`Player.bot?: boolean`（见 `src/network/protocol.ts`）；服务器在 `start` 时若 `clients.size === 1` 就 `push` 三个 bot，回到大厅时过滤掉。
- iPad 入口：大厅里的 **「单人竞速 · 对战 3 名电脑」** 按钮（走 `lobbyDidPlaySoloWithName:kart:host:`），或单人建房后点「单人发车 · 对战电脑」。
- 匹配的游戏侧测试：`npm test`（`tests/network.test.ts` 的 "runs solo AI opponents in quick/arena"）、`npm run test:lan`（`scripts/lan-protocol-test.mjs` 的首段断言 4 人 = 1 真人 + 3 bot）。

## 9. 构建门槛与测试

`build.sh` 现在会**先跑 `tests/run_tests.sh`**（帧编解码 61 断言 + 协议解析 92 断言，在构建机上用 macOS clang 编译执行），不通过就不打包。临时跳过：`PTK_SKIP_TESTS=1 ./build.sh`。

另外两套更重的验证（需要真机或模拟器）：

```bash
# iPad 模拟器 UI 回归：布局不重叠、摇杆映射/死区、隐藏态输入、resize
ssh mini 'export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd ~/PocketTurboKingdom && \
  PTK_SIMULATOR=<simctl 里的 iPad UUID> ./tests/run_ui_tests.sh'
# 结果与截图落在模拟器容器的 Documents 下（PASS: iPad layout, steering, dead zone and input reset）

# 真实联机（服务器 + 浏览器）
npm test && npm run test:lan
```

## 10. 远程调试钩子（无调试器时的抓手）

iPad 上接不了 Xcode，因此客户端留了两个**只靠 SSH 写文件触发**的钩子：

| 触发器 | 作用 |
| --- | --- |
| `touch /tmp/ptk-capture` | 应用每秒把**当前画面**（3D + UIKit 合成）写到容器 `tmp/ptk-screen.png`，日志里出现 `已抓屏 …`；`rm /tmp/ptk-capture` 停止 |
| `/tmp/ptk-autoplay`，内容**必须以 `PTK-AUTOTEST\|` 开头**：`PTK-AUTOTEST\|房间码\|昵称\|车号[\|drive]` | 启动时自动联机（房间码留空＝走「单人竞速」那条产品路径），进房后自动准备、全员就绪即发车。**只有末尾额外写了 `drive` 才会自动驾驶**——曾经因为「文件存在就自动开跑」，残留触发器让用户一打开就看到赛车自己乱撞，所以现在必须显式声明 |

日志在 `.../Containers/Data/Application/<UUID>/tmp/ptk.log`（`启动` / `几何` / `收到房间` / `fps=…` 行，fps 行还带本车名次、圈数、速度）。

## 11. 冷启动看门狗（0x8badf00d）——已缓解

A7 + 1GB 的 iPad mini 2 上，首次冷启动要「解析 4.7 MB 几何 + SceneKit 首次编译 27 个着色器」，实测有 `process-exit watchdog transgression … 5.00 seconds` 被 SpringBoard 杀掉（崩溃日志会出现 `"exception": "0x8badf00d"`）。

缓解措施：`viewDidLoad` 里只建窗口与 UIKit 覆盖层，把 `loadAssets` + 场景装配**推迟 0.2 秒**到首帧之后执行，保证首帧及时呈现。

另外注意：**锁屏状态下无法远程启动应用**（`uiopen --bundleid` 会静默失败，root 与 mobile 都一样），需要先解锁屏幕、或在桌面上手点图标。
