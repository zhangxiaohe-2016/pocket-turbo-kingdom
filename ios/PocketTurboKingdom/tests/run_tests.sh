#!/bin/bash
# run_tests.sh —— 在 macOS 上跑 PTKWebSocket / PTKProtocol 单元测试。
# 只依赖 CommandLineTools 的 clang + Foundation/CFNetwork/Security，不需要 Xcode 工程文件。
#
#   ./run_tests.sh            # 全跑
#   ./run_tests.sh ws         # 只跑帧/WebSocket 测试
#   ./run_tests.sh protocol   # 只跑协议编解码测试
#
# 任一测试失败，脚本返回非零（可以直接当 build.sh 的构建门槛）。
set -uo pipefail

cd "$(dirname "$0")" || exit 1
NET=../client/Net
CFLAGS=(-fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -I"$NET")
LIBS=(-framework Foundation -framework CFNetwork -framework Security)
OUT=${TMPDIR:-/tmp}/ptk_tests
mkdir -p "$OUT"

PASS=0
FAIL=0
FAILED_NAMES=()

build_and_run() {  # build_and_run <名字> <测试源> <被测源...>
  local name="$1" src="$2"
  shift 2
  local sources=()
  for f in "$@"; do sources+=("$NET/$f"); done

  printf '\n\033[1m==> %s\033[0m\n' "$name"
  if ! clang "${CFLAGS[@]}" "$src" "${sources[@]}" "${LIBS[@]}" -o "$OUT/$name"; then
    printf '\033[31m编译失败: %s\033[0m\n' "$name"
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name(编译)")
    return
  fi
  if "$OUT/$name"; then
    PASS=$((PASS + 1))
  else
    printf '\033[31m测试失败: %s\033[0m\n' "$name"
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
  fi
}

want() {  # want <名字>：FILTER 为空则全跑，否则只跑匹配的套件
  local name="$1"
  [ -z "${FILTER:-}" ] && return 0
  [ "$name" = "$FILTER" ] && return 0
  return 1
}

FILTER="${1:-}"

printf 'PTK 协议层测试（clang %s）\n' "$(clang --version | head -1 | sed 's/.*version //')"

want ws && build_and_run ws_frame_test ws_frame_test.m PTKWebSocket.m
want protocol && build_and_run protocol_test protocol_test.m PTKProtocol.m

printf '\n\033[1m===== 结果 =====\033[0m\n'
printf '套件通过 %d，失败 %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '失败项: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
printf '\033[32m全部通过\033[0m\n'
exit 0
