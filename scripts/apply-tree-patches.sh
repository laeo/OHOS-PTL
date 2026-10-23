#!/bin/sh
# 用法: apply-tree-patches.sh <OHOS 树根>
#
# 只按 REPO_HEADS.txt 里的仓列表应用补丁（仓路径 -> 补丁名 = 路径中的 '/' 换成 '_'）。
# 不要用「补丁名反向还原仓路径」，因为仓路径本身含下划线（window_manager、third_party、musl 等）。
set -e
TREE=${1:?usage: apply-tree-patches.sh /path/to/OHOS}
HERE=$(cd "$(dirname "$0")/.." && pwd)
DIR="$HERE/patches/tree-ohos"
n=0; ok=0; skip=0

while read -r repo head; do
  [ -n "$repo" ] || continue
  slug=$(printf '%s' "$repo" | tr '/' '_')
  p="$DIR/$slug.patch"
  [ -f "$p" ] || continue
  n=$((n + 1))
  if [ ! -e "$TREE/$repo/.git" ]; then
    echo "MISSING REPO: $repo"
    skip=$((skip + 1))
    continue
  fi
  if git -C "$TREE/$repo" apply --check "$p" 2>/dev/null; then
    git -C "$TREE/$repo" apply "$p"
    echo "applied:  $repo"
    ok=$((ok + 1))
  else
    echo "SKIP:     $repo  (已应用或冲突，需人工看)"
    skip=$((skip + 1))
  fi
done < "$DIR/REPO_HEADS.txt"

echo "done: $ok applied, $skip skipped, $n considered"
