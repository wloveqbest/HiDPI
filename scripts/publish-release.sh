#!/bin/bash
#
# 用 GitHub API 创建/复用 Release 并上传附件（不依赖 gh CLI）
#
# 用法:
#   export GITHUB_TOKEN=ghp_xxx           # 需要 repo 权限
#   ./scripts/publish-release.sh v1.0.0 dist/HiDPI-1.0.0.dmg
#
# 可选环境变量:
#   OWNER=wloveqbest   REPO=HiDPI   NAME="v1.0.0"
#
set -euo pipefail

TAG="${1:?用法: publish-release.sh <tag> <文件>}"
ASSET="${2:?用法: publish-release.sh <tag> <文件>}"

OWNER="${OWNER:-wloveqbest}"
REPO="${REPO:-HiDPI}"
NAME="${NAME:-$TAG}"

: "${GITHUB_TOKEN:?请先 export GITHUB_TOKEN=<有 repo 权限的 token>}"

if [ ! -f "$ASSET" ]; then
  echo "找不到文件: $ASSET" >&2
  exit 1
fi

API="https://api.github.com/repos/$OWNER/$REPO"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")

echo "==> 查询是否已有 release: $TAG"
RELEASE_ID=$(curl -sS "${AUTH[@]}" "$API/releases/tags/$TAG" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    print('')
    sys.exit(0)
print(data.get('id', ''))
")

if [ -z "$RELEASE_ID" ]; then
  echo "==> 创建 release $TAG"
  BODY_FILE="$(mktemp)"
  {
    echo "首个可日常使用的版本。"
    echo
    if [ -f CHANGELOG.md ]; then
      # 取 CHANGELOG 中该 tag 的段落（去掉首个标题行）
      awk -v tag="## $TAG" 'index($0, tag) == 1 {flag=1; next} /^## / {flag=0} flag' CHANGELOG.md | sed '/^$/N;/^\n$/D'
    fi
  } > "$BODY_FILE"

  RESPONSE=$(curl -sS "${AUTH[@]}" -X POST "$API/releases" \
    -d "$(python3 -c "
import json, sys, pathlib
print(json.dumps({
    'tag_name': '$TAG',
    'name': '$NAME',
    'body': pathlib.Path('$BODY_FILE').read_text(),
    'draft': False,
    'prerelease': False,
}))")")
  rm -f "$BODY_FILE"

  RELEASE_ID=$(printf '%s' "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'id' not in data:
    print('创建失败:', data, file=sys.stderr)
    sys.exit(1)
print(data['id'])
")
  echo "    release id = $RELEASE_ID"
else
  echo "    已存在，复用 release id = $RELEASE_ID"
fi

echo "==> 上传附件 $(basename "$ASSET")"
UPLOAD_URL="https://uploads.github.com/repos/$OWNER/$REPO/releases/$RELEASE_ID/assets?name=$(basename "$ASSET")"
curl -sS "${AUTH[@]}" -H "Content-Type: application/octet-stream" \
  --data-binary "@$ASSET" -X POST "$UPLOAD_URL" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if 'browser_download_url' in data:
    print('    上传成功:', data['browser_download_url'])
else:
    print('    上传失败:', data, file=sys.stderr)
    sys.exit(1)
"

echo
echo "完成: https://github.com/$OWNER/$REPO/releases/tag/$TAG"
