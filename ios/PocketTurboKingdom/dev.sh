#!/bin/bash
# Pocket Turbo Kingdom —— 本机驱动脚本（本机没有 Xcode，编译交给构建机）
#
#   ./dev.sh              同步源码 → 构建机编译打包 → 取回 .deb 到 dist/
#   ./dev.sh publish      上面全部做完后，再把 .deb 发到构建机上的 APT 源
#
# 构建机默认用 ssh 别名 mini（Tailscale 100.65.190.37），可用 MINI 覆盖：
#   MINI=user@host ./dev.sh
#   MINI=mini APT_REPO=~/apt-repo ./dev.sh publish
#
# 发布相关环境变量（透传到构建机）：
#   APT_REPO        构建机上 APT 源仓库路径；留空则自动探测 ~/apt-repo → ~/ipad-second-monitor/repo
#   APT_PUBLISHER   重新生成 Packages/Release 并签名的脚本；留空则用 <repo>/publish-repo.py
set -euo pipefail

MINI=${MINI:-mini}
MODE=${1:-build}

SRC="$(cd "$(dirname "$0")" && pwd)"
REMOTE_DIR="PocketTurboKingdom"
APT_REPO=${APT_REPO:-}
APT_PUBLISHER=${APT_PUBLISHER:-}

echo "==> 构建机: $MINI    远程目录: ~/$REMOTE_DIR    模式: $MODE"
echo "==> 同步源码: $SRC → $MINI:~/$REMOTE_DIR"
ssh "$MINI" "mkdir -p ~/$REMOTE_DIR"
rsync -a --delete \
  --exclude build --exclude dist --exclude .build \
  --exclude node_modules --exclude .git \
  "$SRC/" "$MINI:~/$REMOTE_DIR/"

echo "==> 在构建机上编译 + 打包"
# build.sh 的覆盖项原样透传到构建机（例如先用 tools/hello.m 验证链路：
#   PTK_ENTRY=tools/hello.m PTK_SOURCES=tools/hello.m APP_NAME=PocketTurboHello ./dev.sh）
REMOTE_ENV=""
for v in PTK_ENTRY PTK_SOURCES APP_NAME APP_BUNDLE_ID APP_DISPLAY_NAME APP_VERSION PKG_ID; do
  if [ -n "${!v:-}" ]; then
    # 必须 export：`VAR=x cmd` 这种前缀赋值只作用于 cmd 本身，传不到后面的 ./build.sh
    REMOTE_ENV="$REMOTE_ENV export $v=$(printf '%q' "${!v}");"
  fi
done
[ -n "$REMOTE_ENV" ] && echo "==> 透传覆盖:$REMOTE_ENV"
ssh "$MINI" "export PATH=/opt/homebrew/bin:\$PATH;$REMOTE_ENV cd ~/$REMOTE_DIR && chmod +x build.sh && ./build.sh"

echo "==> 取回 .deb 到 $SRC/dist"
mkdir -p "$SRC/dist"
# 远端 dist/ 里只有 .deb；用 include/exclude 过滤，避免把中间的 build 目录带回来
rsync -a --include='*.deb' --exclude='*' "$MINI:~/$REMOTE_DIR/dist/" "$SRC/dist/"

shopt -s nullglob
local_debs=("$SRC/dist"/*.deb)
shopt -u nullglob
if [ ${#local_debs[@]} -eq 0 ]; then
  echo "错误：没有从构建机取回任何 .deb" >&2
  exit 1
fi
echo "==> 本地 dist/ 里的 .deb:"
ls -lh "${local_debs[@]}" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 可选：发布到 APT 源（在构建机上执行；不存在仓库时给提示而不报错退出）
# ---------------------------------------------------------------------------
if [ "$MODE" = "publish" ]; then
  echo "==> 发布到构建机上的 APT 源"
  ssh "$MINI" \
    "APT_REPO='$APT_REPO' APT_PUBLISHER='$APT_PUBLISHER' REMOTE_DIR='$REMOTE_DIR' bash -s" <<'REMOTE_PUBLISH'
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH

DIST="$HOME/$REMOTE_DIR/dist"
shopt -s nullglob
debs=("$DIST"/*.deb)
shopt -u nullglob
if [ ${#debs[@]} -eq 0 ]; then
  echo "错误：构建机上 $DIST 里没有 .deb" >&2
  exit 1
fi

# 找 APT 源仓库：显式指定 > ~/apt-repo > 本机已知的 iPad mini 2 公共源
REPO="${APT_REPO:-}"
if [ -z "$REPO" ]; then
  for cand in "$HOME/apt-repo" "$HOME/ipad-second-monitor/repo"; do
    if [ -d "$cand/.git" ]; then REPO="$cand"; break; fi
  done
fi
# 经 ssh 传过来的 "~/..." 不会展开，这里显式补一下（用绝对路径最稳）
case "$REPO" in
  "~/"*) REPO="$HOME/${REPO#\~/}" ;;
  "~")   REPO="$HOME" ;;
esac
if [ -z "$REPO" ] || [ ! -d "$REPO/.git" ]; then
  cat >&2 <<'HINT'

⚠️  构建机上没有找到可用的 APT 源仓库，已跳过 publish（构建本身是成功的）。
    探测过的位置：~/apt-repo、~/ipad-second-monitor/repo
    想发布的话，先确认仓库在哪，然后显式指定，例如：
        MINI=mini APT_REPO=~/apt-repo ./dev.sh publish
    或者干脆不发布：把 dist/*.deb 传到 iPad 上用 dpkg -i 装（见 INSTALL.md）。
HINT
  exit 0
fi

# 索引生成脚本
PUB="${APT_PUBLISHER:-}"
if [ -z "$PUB" ]; then
  for cand in "$REPO/publish-repo.py" "$REPO/../publish-repo.py"; do
    if [ -f "$cand" ]; then PUB="$cand"; break; fi
  done
fi
if [ -z "$PUB" ] || [ ! -f "$PUB" ]; then
  echo "⚠️  找不到索引生成脚本（\$REPO/publish-repo.py），已跳过 publish。" >&2
  echo "    可用 APT_PUBLISHER=/path/to/publish-repo.py 指定。" >&2
  exit 0
fi

echo "==> APT 仓库: $REPO"
echo "==> 索引脚本: $PUB"
mkdir -p "$REPO/debs"
for d in "${debs[@]}"; do
  echo "==> 加入源: $(basename "$d")"
  cp -f "$d" "$REPO/debs/"
done

# 同一个包的旧版本删掉，Sileo 只会看到最新版
for d in "${debs[@]}"; do
  base=$(basename "$d")
  pkg="${base%%_*}"
  for old in "$REPO/debs/${pkg}"_*.deb; do
    [ -e "$old" ] || continue
    [ "$(basename "$old")" = "$base" ] && continue
    echo "==> 移除旧版本: $(basename "$old")"
    rm -f "$old"
  done
done

cd "$REPO"
python3 "$PUB"

if [ -d .git ]; then
  git add -A
  if git diff --cached --quiet; then
    echo "==> 索引无变化，跳过提交"
  else
    git commit -m "Add $(basename "${debs[0]}")"
    git push origin "$(git rev-parse --abbrev-ref HEAD)"
    echo "==> 已推送到 APT 源（GitHub Pages 通常 1 分钟内生效）"
  fi
fi
REMOTE_PUBLISH
  echo "==> publish 流程结束"
fi
