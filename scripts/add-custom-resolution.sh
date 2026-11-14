#!/bin/bash
#
# 给真实显示器新增自定义缩放分辨率（BetterDisplay 的 flexible scaling 走的就是这条路）
#
# 原理：往 /Library/Displays/Contents/Resources/Overrides/ 下写入该显示器 vendor/model
#       对应的 plist，macOS 下次枚举显示器时就会把这些 scale-resolutions 加进模式表。
#       需要 root（写入 /Library），并且影响所有同 vendor/model 的显示器。
#
# 用法:
#   ./scripts/add-custom-resolution.sh <displayID> <逻辑分辨率WxH> [更多WxH...] [--dry-run]
#   ./scripts/add-custom-resolution.sh <displayID> --remove
#
# 例：给 4K 屏增加 1920x1080 与 1600x900 两档 HiDPI
#   ./scripts/add-custom-resolution.sh 2 1920x1080 1600x900
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/hidpi"

if [ ! -x "$BIN" ]; then
  echo "找不到 $BIN，请先执行: swift build -c release" >&2
  exit 1
fi

if [ $# -lt 2 ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

DISPLAY_ID="$1"
shift

REMOVE=0
DRY_RUN=0
NO_ACTIVATE=0
SIZES=()
for arg in "$@"; do
  case "$arg" in
    --remove) REMOVE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-activate) NO_ACTIVATE=1 ;;
    [0-9]*x[0-9]*) SIZES+=("$arg") ;;
    *) echo "无法识别的参数: $arg" >&2; exit 1 ;;
  esac
done

# 模式表快照：逻辑尺寸 + HiDPI/LoDPI
snapshot_modes() {
  "$BIN" modes "$1" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $2, $5}' | sort -u
}

if [ "$REMOVE" -eq 0 ] && [ ${#SIZES[@]} -eq 0 ]; then
  echo "至少给一个逻辑分辨率，例如 1920x1080" >&2
  exit 1
fi

VENDOR=$("$BIN" info "$DISPLAY_ID" | sed -n 's/.*厂商号.*(\([0-9]*\)).*/\1/p' | head -1)
PRODUCT=$("$BIN" info "$DISPLAY_ID" | sed -n 's/.*型号号.*(\([0-9]*\)).*/\1/p' | head -1)

if [ -z "$VENDOR" ] || [ -z "$PRODUCT" ]; then
  echo "无法读取显示器 $DISPLAY_ID 的 vendor/product" >&2
  exit 1
fi

DIR="/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-$VENDOR"
FILE="$DIR/DisplayProductID-$PRODUCT"

echo "显示器 $DISPLAY_ID → vendor=$VENDOR product=$PRODUCT"
echo "目标文件: $FILE"

if [ "$REMOVE" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] 将删除 $FILE"
    exit 0
  fi
  sudo rm -f "$FILE"
  sudo defaults delete /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled 2>/dev/null || true
  echo "已删除 override，接下来重新枚举显示器…"
  "$BIN" activate || true
  exit 0
fi

# 生成 plist：scale-resolutions 里放的是「背衬像素尺寸」，每项 8 字节大端 (width, height)
PLIST=$(python3 - "$@" <<'PY'
import struct, sys, plistlib

sizes = []
for token in sys.argv[1:]:
    if not token[0].isdigit():
        continue
    w, h = (int(x) for x in token.lower().split("x"))
    # HiDPI：逻辑尺寸对应的背衬是 2 倍
    sizes.append((w * 2, h * 2))

pl = {
    "DisplayResolutionEnabled": True,
    "scale-resolutions": [struct.pack(">II", w, h) for w, h in sizes],
}
sys.stdout.write(plistlib.dumps(pl, fmt=plistlib.FMT_XML).decode())
PY
)

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] 将写入以下内容:"
  echo "$PLIST"
  exit 0
fi

BEFORE="$(snapshot_modes "$DISPLAY_ID")"

# macOS 还需要一个全局开关，允许 windowserver 采信 scale-resolutions
# （BetterDisplay 内部执行的就是同一条 defaults write）
sudo defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool YES

sudo mkdir -p "$DIR"
printf '%s\n' "$PLIST" | sudo tee "$FILE" >/dev/null
sudo chmod 644 "$FILE"
echo "已写入 $FILE"

if [ "$NO_ACTIVATE" -eq 1 ]; then
  echo "已写入（跳过激活）。手动激活: $BIN activate"
else
  echo "激活配置（屏幕会闪一下）…"
  "$BIN" activate || true
fi

AFTER="$(snapshot_modes "$DISPLAY_ID")"
echo
echo "=== 模式表变化 ==="
ADDED="$(comm -13 <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | sed '/^$/d')"
if [ -n "$ADDED" ]; then
  echo "新增档位:"
  printf '%s\n' "$ADDED" | sed 's/^/  + /'
else
  echo "没有新档位出现（override 未被采信，或该尺寸系统直接拒绝）。"
  echo "当前档位数: $(printf '%s\n' "$AFTER" | sed '/^$/d' | wc -l | tr -d ' ')"
fi

cat <<'TIP'

但 override 写进去≠立刻生效，WindowServer 只在「重新枚举显示器」时才重读它。
BetterDisplay 把这个步骤叫做 activation：Apple Silicon 上它会切断外接屏的链路
2–4 秒（屏幕黑一下），内建屏则必须重启；我们没做这套，所以需要你手动触发：

  1. 点 App 菜单里的「重新枚举显示器」，再看列表
  2. 拔插显示器线缆（外接屏）
  3. 重启 Mac

查看结果:
  ./hidpi list
  ./hidpi modes <displayID>
回滚:
  ./scripts/add-custom-resolution.sh <displayID> --remove
TIP
