#!/bin/bash
# fix_desktop2/inject.sh
#
#   inject.sh <image> [hap] [hidumper_so] [ohos_diag]
#
# 把 fix_desktop2 的三个产物注入 pc_ptl 磁盘镜像的 **p2(system)** 分区：
#
#   1) /system/app/SceneBoard/SceneBoard.hap
#        -> 预置 layoutInfo.json 的每个条目补上 "area":[1,1] 和 "page":0
#        -> PcPageDesktopLayoutConfig 运行时归一化 area/page 并落库
#           （**桌面空白的真正原因**：没有 page 的桌面项会被 integrateSwiper() 丢掉）
#        -> filterItemExceedCurrentScreen() 不再吞掉 area 坏掉的桌面项
#        -> 桌面页一个图标都没画出来时兜底用已装 app 重建布局
#        -> 新增 DESKTOPLAYOUT / DESKTOPICONS / DESKTOPFILTER / DESKTOPREPAIR 自证日志
#   2) /system/lib64/libhidumperservice.z.so
#        -> DumpManagerService::HasDumpPermission() 在 ATK 判定失败时对 root 放行
#           （之前 console/diag 都是 root 也只能拿到 "request error"）
#   3) /system/bin/ohos-diag
#        -> 新增判据 desktop/db-area / desktop/icons-rendered /
#           desktop/filter-dropped / desktop/area-normalize / hidumper/dump-permission
#
#   4) /system/etc/ohos-diag/fix_manifest.txt
#        -> 同步更新上面三个文件的 sha256（否则 ohos-diag 的 fix/* 检查会 MISMATCH）
#
# 关键点
#  * p2 空闲只有 ~24MiB，而 HAP 有 ~91MiB —— 先 `rm` 旧 HAP（释放 ~91MiB）再 `write`，
#    因此可以原地替换，不需要挪到 p3(/vendor)，也不需要改 install_list.json
#    （bundleName / 模块名 / 安装路径都没变）。
#  * 幂等：重复执行得到同样的结果（rm + write 同一份文件）。
#  * 不改 GPT、不改镜像大小。
set -eu

BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
TASK=$BASE/fix_desktop2
W=$TASK/work
STAGE=$TASK/stage

IMG=${1:-$BASE/partdisk/media/ohos_part_pc_ptl.img}
HAP=${2:-$BASE/porting/scb_src/product/pc/build/default/outputs/default/pc_sceneboard-default-signed.hap}
HSO=${3:-/home/katax/Public/OHOS/out/ptl/hiviewdfx/hidumper/libhidumperservice.z.so}
DIAG=${4:-/home/katax/Public/OHOS/base/startup/ohos_diag/ohos-diag}

for f in "$IMG" "$HAP" "$HSO" "$DIAG"; do
  [ -f "$f" ] || { echo "ERROR: file not found: $f"; exit 1; }
done

mkdir -p "$W" "$STAGE"
P2_OFF_MB=513           # p2 (system) 起始偏移 = 扇区 1050624 * 512 / 1MiB
P2_LEN_MB=2048          # p2 大小

HAP_PATH=/system/app/SceneBoard/SceneBoard.hap
HSO_PATH=/system/lib64/libhidumperservice.z.so
DIAG_PATH=/system/bin/ohos-diag
MANIFEST_PATH=/system/etc/ohos-diag/fix_manifest.txt

echo "=== image : $IMG"
echo "=== hap   : $HAP"
echo "=== hidumper so : $HSO"
echo "=== ohos-diag   : $DIAG"
sha256sum "$HAP" "$HSO" "$DIAG" | sed 's/^/    /'
echo "--- sha256 of image BEFORE: $(sha256sum "$IMG" | cut -d' ' -f1)"

# ---------------------------------------------------------------- 1) 抽 p2
echo "--- extracting p2 ..."
dd if="$IMG" of="$W/inject_p2.img" bs=1M skip=$P2_OFF_MB count=$P2_LEN_MB status=none

# ---------------------------------------------------------------- 2) manifest
echo "--- updating fix_manifest.txt ..."
debugfs -R "dump $MANIFEST_PATH $W/fix_manifest.txt" "$W/inject_p2.img" >/dev/null 2>&1 || true
if [ ! -f "$W/fix_manifest.txt" ]; then
  echo "ERROR: $MANIFEST_PATH not found in the image"; exit 1
fi
cp -f "$W/fix_manifest.txt" "$W/fix_manifest.txt.orig"
python3 - "$W/fix_manifest.txt" "$HAP" "$HSO" "$DIAG" <<'PY'
import hashlib, os, sys
manifest, hap, hso, diag = sys.argv[1:5]
def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()
updates = {
    '/system/app/SceneBoard/SceneBoard.hap':
        (sha(hap), 'pc-desktop-page-area',
         '§38 PC 桌面图标：预置 layoutInfo.json 每项补 area=[1,1] 与 page=0；运行时归一化 area/page 并落库'
         '（integrateSwiper 会丢掉没有 page 的桌面项 -> 桌面一个图标都不显示）；'
         'filterItemExceedCurrentScreen 不再吞掉 area 坏掉的桌面项；桌面空时兜底用已装 app 重建',
         'RDB gridlayout_info 桌面项 page_index/width/height 均非 NULL；hilog DESKTOPICONS rendered>0；'
         'RS 树里有 SwiperPage_AppItem_* 节点'),
    '/system/lib64/libhidumperservice.z.so':
        (sha(hso), 'hidumper-root-dump',
         '§37 hidumper：ATK 判定失败时对 root(uid 0) 调用方放行（之前 root 也只能 request error）',
         "hidumper -s RenderService -a gles 能出 GL_RENDERER"),
    '/system/bin/ohos-diag':
        (sha(diag), 'diag-desktop-page-area',
         '§38 ohos-diag 增加 desktop/db-page、desktop/db-area、desktop/icons-rendered、'
         'desktop/filter-dropped、desktop/area-normalize、desktop/integrate-swiper、'
         'desktop/rs-icon-nodes、hidumper/dump-permission 判据',
         'VERDICT.txt 里这些判据为 PASS'),
}
out = []
seen = set()
for line in open(manifest):
    line = line.rstrip('\n')
    if line.startswith('#') or '|' not in line:
        out.append(line); continue
    parts = line.split('|')
    path = parts[0].strip()
    if path in updates:
        s, fid, what, crit = updates[path]
        parts[1] = s
        parts[2] = fid
        parts[3] = what
        parts[4] = crit
        seen.add(path)
        line = '|'.join(parts)
    out.append(line)
# 新增不在清单里的条目
for path, (s, fid, what, crit) in updates.items():
    if path not in seen:
        out.append('|'.join([path, s, fid, what, crit]))
open(manifest, 'w').write('\n'.join(out) + '\n')
print('    manifest updated')
PY
{
  echo "rm $MANIFEST_PATH"
  echo "write $W/fix_manifest.txt $MANIFEST_PATH"
} | debugfs -w "$W/inject_p2.img" 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------- 3) 三个文件
echo "--- replacing $HAP_PATH / $HSO_PATH / $DIAG_PATH ..."
{
  echo "rm $HAP_PATH"
  echo "write $HAP $HAP_PATH"
  echo "rm $HSO_PATH"
  echo "write $HSO $HSO_PATH"
  echo "rm $DIAG_PATH"
  echo "write $DIAG $DIAG_PATH"
} | debugfs -w "$W/inject_p2.img" 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------- 4) fsck
echo "--- e2fsck ..."
e2fsck -f -y "$W/inject_p2.img" > "$W/inject_e2fsck.log" 2>&1 || true
tail -3 "$W/inject_e2fsck.log" | sed 's/^/    /'

# ---------------------------------------------------------------- 5) 写回
echo "--- writing p2 back ..."
dd if="$W/inject_p2.img" of="$IMG" bs=1M seek=$P2_OFF_MB count=$P2_LEN_MB conv=notrunc,fsync status=none

# ---------------------------------------------------------------- 6) 校验
echo "--- verifying (dump back from the image) ..."
RC=0
for pair in "$HAP_PATH:$HAP:check_hap" "$HSO_PATH:$HSO:check_hso" "$DIAG_PATH:$DIAG:check_diag"; do
  p=${pair%%:*}; rest=${pair#*:}; src=${rest%%:*}; out=${rest##*:}
  debugfs -R "dump $p $W/$out" "$W/inject_p2.img" >/dev/null 2>&1
  a=$(sha256sum "$src" | cut -d' ' -f1)
  b=$(sha256sum "$W/$out" | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then
    echo "    OK   $p  $b"
  else
    echo "    FAIL $p  expected=$a actual=$b"
    RC=1
  fi
done
debugfs -R "dump $MANIFEST_PATH $W/check_manifest.txt" "$W/inject_p2.img" >/dev/null 2>&1
echo "    manifest in image:"
grep -a -E "SceneBoard.hap|libhidumperservice|ohos-diag" "$W/check_manifest.txt" | cut -c1-160 | sed 's/^/      /'
echo "--- sha256 of image AFTER : $(sha256sum "$IMG" | cut -d' ' -f1)"
[ "$RC" = 0 ] || { echo "ERROR: verification failed"; exit 1; }
echo "=== OK: fix_desktop2 injected into $IMG"
