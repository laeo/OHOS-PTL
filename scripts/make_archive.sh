#!/bin/bash
# 生成 OHOS pc_ptl 工作归档（改动/补丁/脚本/报告/产物）。
# 用法: bash make_archive.sh [输出目录名]
set -u
ROOT=/home/katax/Public/OHOS
DBG=$ROOT/out/x86_64_virt/ohos-dbg
A=${1:-$DBG/ARCHIVE_2026-10-22}
LOG=$DBG/make_archive.log
: > "$LOG"

say() { echo "$@" | tee -a "$LOG"; }
mkdir -p "$A"/{01_tree_patches,02_tree_new_files,03_out_patches,04_scripts/injectors,04_scripts/partdisk,04_scripts/tools,05_reports,06_artifacts/hap,06_artifacts/libs,06_artifacts/mesa,06_artifacts/hwdec}

# 需要归档的（我们改过的）git 仓
REPOS="vendor/ohemu build foundation/multimodalinput/input foundation/graphic/graphic_2d \
foundation/window/window_manager foundation/communication/wifi \
foundation/communication/bluetooth_service foundation/bundlemanager/bundle_framework \
applications/standard/settings device/qemu drivers/peripheral drivers/hdf_core \
drivers/interface base/startup/init base/hiviewdfx/hidumper base/inputmethod/imf \
base/global/system_resources kernel/linux/build third_party/wpa_supplicant \
third_party/alsa-lib third_party/musl foundation/ability/ability_runtime"

# 噪声过滤：构建产物 / 锁文件 / 生成代码
EXCL='package-lock\.json|\.hvigor|oh_modules|node_modules|(^|/)build/|\.log$|local\.properties'

say "=== 1) 逐仓生成并集补丁 ==="
: > "$A/REPO_HEADS.txt"
for r in $REPOS; do
  slug=$(echo "$r" | tr '/' '_')
  st=$(git -C "$ROOT/$r" status --porcelain 2>/dev/null | grep -vE "$EXCL")
  [ -z "$st" ] && { say "  - $r  (无改动，跳过)"; continue; }
  head=$(git -C "$ROOT/$r" rev-parse HEAD 2>/dev/null)
  echo "$r  $head" >> "$A/REPO_HEADS.txt"
  mod=$(echo "$st" | awk '$1!="??"{print $2}')
  unt=$(echo "$st" | awk '$1=="??"{print $2}')
  if [ -n "$mod" ]; then
    ( cd "$ROOT/$r" && git diff -- $mod ) > "$A/01_tree_patches/$slug.patch"
    say "  + $slug.patch  ($(grep -c '^diff --git' "$A/01_tree_patches/$slug.patch") 文件)"
  fi
  if [ -n "$unt" ]; then
    for u in $unt; do
      mkdir -p "$A/02_tree_new_files/$slug/$(dirname "$u")"
      cp -a "$ROOT/$r/$u" "$A/02_tree_new_files/$slug/$u" 2>/dev/null
    done
    say "  + 新增文件 $slug: $(echo "$unt" | wc -l) 项"
  fi
done

# ace_engine 只取我们改的 text_field_pattern.cpp（其余为构建生成）
say "=== 2) ace_engine（仅 text_field_pattern.cpp）==="
( cd "$ROOT/foundation/arkui/ace_engine" && \
  git diff -- frameworks/core/components_ng/pattern/text_field/text_field_pattern.cpp ) \
  > "$A/01_tree_patches/foundation_arkui_ace_engine.patch"
echo "foundation/arkui/ace_engine  $(git -C "$ROOT/foundation/arkui/ace_engine" rev-parse HEAD)" >> "$A/REPO_HEADS.txt"

# 工作区内新增的整目录（无 git）
say "=== 3) 工作区新增目录 ==="
for d in device/pc vendor/pc applications/standard/terminal applications/standard/rime_ime \
         base/startup/ohos_diag third_party/aira; do
  tgt=$A/02_tree_new_files/_worktree/$(echo "$d" | tr '/' '_')
  mkdir -p "$tgt"
  rsync -a --exclude '.hvigor' --exclude 'oh_modules' --exclude 'node_modules' \
        --exclude 'build/' --exclude 'local.properties' --exclude '*.log' \
        "$ROOT/$d/" "$tgt/" 2>/dev/null
  say "  + $d  $(du -sh "$tgt" | cut -f1)"
done

# kernel 新增 defconfig 目录
say "=== 4) kernel 新增 defconfig ==="
for d in linux-7.2 linux-6.18; do
  [ -d "$ROOT/kernel/linux/config/$d" ] || continue
  mkdir -p "$A/02_tree_new_files/kernel_linux_config/$d"
  rsync -a --exclude '*.o' --exclude '.config*' "$ROOT/kernel/linux/config/$d/" \
        "$A/02_tree_new_files/kernel_linux_config/$d/" 2>/dev/null
  say "  + kernel/linux/config/$d  $(du -sh "$A/02_tree_new_files/kernel_linux_config/$d" | cut -f1)"
done

# out/ 下的补丁文件
say "=== 5) out 补丁 ==="
n=0
while read -r p; do
  case "$p" in */work/*|*/scratch*|*/node_modules/*) continue;; esac
  t=$A/03_out_patches/$(dirname "${p#$DBG/}" | tr '/' '_')_$(basename "$p")
  cp -a "$p" "$t" && n=$((n+1))
done < <(find "$DBG" -maxdepth 3 -name '*.patch' -not -path '*/work/*')
say "  + $n 个补丁"

# 脚本
say "=== 6) 脚本 ==="
for d in "$DBG"/fix_*; do
  [ -f "$d/inject.sh" ] && cp -a "$d/inject.sh" "$A/04_scripts/injectors/$(basename "$d")_inject.sh"
done
for d in "$DBG"/fix_*; do
  [ -d "$d/scripts" ] && cp -a "$d/scripts" "$A/04_scripts/injectors/$(basename "$d")_scripts" 2>/dev/null
done
cp -a "$DBG"/partdisk/*.sh "$A/04_scripts/partdisk/" 2>/dev/null
cp -a "$DBG"/partdisk/*.md "$A/04_scripts/partdisk/" 2>/dev/null
cp -a "$DBG"/partdisk/sb_keys "$A/04_scripts/partdisk/" 2>/dev/null
mkdir -p "$A/04_scripts/partdisk/grub"
cp -a "$DBG"/partdisk/grub/{mkpatch.py,grub.sbat,build_grub.sh,README*,*.patch,*.diff} "$A/04_scripts/partdisk/grub/" 2>/dev/null
cp -a "$DBG"/partdisk/grub/dist "$A/04_scripts/partdisk/grub/" 2>/dev/null
cp -a "$DBG"/partdisk/grub/grub2_2.14.orig.tar.xz "$A/04_scripts/partdisk/grub/" 2>/dev/null
cp -a "$DBG"/rebuild_chain.sh "$A/04_scripts/" 2>/dev/null
rsync -a --include '*/' --include '*.py' --include '*.sh' --exclude '*' --exclude '__pycache__' "$DBG/scripts/" "$A/04_scripts/debug/" 2>/dev/null
cp -a "$DBG"/tools/*.c "$A/04_scripts/tools/" 2>/dev/null
cp -a "$DBG"/scripts/tools/*.c "$A/04_scripts/tools/" 2>/dev/null
cp -a "$DBG"/fix_hwdec_probe/{build_probe.sh,package.sh,inject.sh,ohos_x86_64.cmake,ohos_x86_64_cross.ini} "$A/04_scripts/tools/" 2>/dev/null
cp -a "$DBG"/hwdec_probe 2>/dev/null && true
say "  + $(find "$A/04_scripts" -type f | wc -l) 个文件"

# 报告
say "=== 7) 报告 ==="
for f in "$DBG"/fix_*/SUMMARY*.md "$DBG"/*STATUS*.md "$DBG"/ARKUI_UI_STANDARD.md; do
  [ -f "$f" ] && cp -a "$f" "$A/05_reports/$(dirname "${f#$DBG/}" | tr '/' '_')_$(basename "$f")"
done
cp -a "$ROOT/AGENTS.md" "$A/05_reports/AGENTS.md" 2>/dev/null
say "  + $(ls "$A/05_reports" | wc -l) 份"

# 产物：直接从交付镜像抽取（权威字节）
say "=== 8) 从交付镜像抽取产物 ==="
IMG=$DBG/partdisk/media/ohos_part_pc_ptl.img
P2=$DBG/p2_probe.img; P3=$DBG/p3_probe.img
[ -f "$P2" ] || dd if="$IMG" bs=512 skip=1050624 count=4194304 status=none > "$P2"
[ -f "$P3" ] || dd if="$IMG" bs=512 skip=5244928 count=1048576 status=none > "$P3"
D=$A/06_artifacts/delivered
mkdir -p "$D/p2" "$D/p3"
dump_part() { # $1=分区标签(p2|p3) $2=分区镜像 $3=镜像内目录 $4=正则
  local lbl=$1 img=$2 dir=$3 pat=$4
  for f in $(debugfs -R "ls $dir" "$img" 2>/dev/null | tr ' ' '\n' | grep -E "$pat" | grep -v '^\.'); do
    mkdir -p "$D/$lbl/$(echo $dir | sed 's|^/||')" 2>/dev/null
    debugfs -R "dump $dir/$f $D/$lbl/$(echo $dir | sed 's|^/||')/$f" "$img" 2>/dev/null
  done
}
# p2: 应用 HAP
dump_part p2 "$P2" /system/app/SceneBoard '\.hap$'
dump_part p2 "$P2" /system/app/org.aira.browser '\.hap$'
dump_part p2 "$P2" /system/app/com.ohos.browser '\.hap$'
dump_part p2 "$P2" /system/app/Terminal '\.hap$'
dump_part p2 "$P2" /system/app/com.ohos.rimeime '\.hap$'
dump_part p2 "$P2" /system/app/com.example.kikakeyboard '\.hap$'
dump_part p2 "$P2" /system/app/com.ohos.systemui '\.hap$'
# p2: 库 / 二进制 / 脚本 / 配置
dump_part p2 "$P2" /system/lib64 '^(librender_service\.z\.so|libcursor_drawing_adapter\.z\.so|libhidumperservice\.z\.so|libgallium-26\.2\.3\.so|libEGL\.so\.1\.0\.0|libGLESv1_CM\.so\.1\.1\.0|libGLESv2\.so\.2\.0\.0|libgbm\.so\.1\.0\.0|libmmi-server\.z\.so|libmmi-client\.z\.so|libwms\.z\.so)$'
dump_part p2 "$P2" /system/lib64/platformsdk '^(libmmi-util\.z\.so|librender_service_base\.z\.so)$'
dump_part p2 "$P2" /system/bin '^(ohos-diag|hwdec_probe|hwdec_probe\.sh|bt_enable|bt_diag\.sh|ohosshd|ohosptyd|zz_.*|libshim.*)$'
dump_part p2 "$P2" /system/etc/init '^zz_.*\.cfg$'
mkdir -p "$D/p2/etc"
for f in /system/etc/ohos-image-id /system/etc/ohos-image-id.manifest; do
  debugfs -R "dump $f $D/p2/etc/$(basename $f)" "$P2" 2>/dev/null || true
done
for f in /system/lib/firmware/xe/ptl_guc_70.bin /system/lib/firmware/regulatory.db; do
  mkdir -p "$D/p2/firmware/$(dirname ${f#/system/lib/firmware/})"
  debugfs -R "dump $f $D/p2/firmware/${f#/system/lib/firmware/}" "$P2" 2>/dev/null || true
done
# p3: 硬解栈 + 音频 + 蓝牙 vendor
dump_part p3 "$P3" /lib64 '^(libasound\.so|libva\.so\..*|libigdgmm\.so\..*|libvpl\.so.*|libmfx-gen\.so.*|libaudio_render_adapter\.z\.so|libaudio_capture_adapter\.z\.so|libbluetooth_hci_hdi_driver\.z\.so|libbt_vendor.*\.so)$'
dump_part p3 "$P3" /lib64/dri '.*'
debugfs -R "dump /etc/init.hwdec_probe.cfg $D/p3/etc/init.hwdec_probe.cfg" "$P3" 2>/dev/null || true

# 构建期中间产物（非最终态，仅供追溯）
B=$A/06_artifacts/builds
mkdir -p "$B"
cp -a "$DBG/fix_alsa_bt_desktop/files" "$B/alsa_bt_desktop_files" 2>/dev/null
cp -a "$DBG/fix_alsa_bt_desktop/stage" "$B/alsa_bt_desktop_stage" 2>/dev/null
cp -a "$DBG/fix_sof_topo/files"         "$B/sof_topo_files"        2>/dev/null
cp -a "$DBG/fix_sof_topo/stage"         "$B/sof_topo_stage"        2>/dev/null
cp -a "$DBG/fix_net_perf/files"         "$B/net_perf_files"        2>/dev/null
cp -a "$DBG/fix_hwdec2/stage"           "$B/hwdec_stage"           2>/dev/null
mkdir -p "$A/06_artifacts/source/mesa"
cp -a "$DBG/mesa_build26/mesa3d-src/src/egl/drivers/dri2/platform_ohos.c" "$A/06_artifacts/source/mesa/platform_ohos.c" 2>/dev/null
cp -a "$DBG/mesa_build26/mesa3d-src/src/egl/drivers/dri2/egl_dri2.h"      "$A/06_artifacts/source/mesa/egl_dri2.h" 2>/dev/null
cp -a "$DBG/mesa_build/mesa3d-src/src/egl/drivers/dri2/platform_ohos.c"   "$A/06_artifacts/source/mesa/platform_ohos.c.20260923" 2>/dev/null
say "  + delivered $(du -sh "$D" | cut -f1) / builds $(du -sh "$B" | cut -f1)"
( cd "$D" && find . -type f -print0 | xargs -0 sha256sum > ../../DELIVERED_SHA256SUMS ) 2>/dev/null
say "  交付镜像 sha: $(sha256sum "$IMG" | cut -d' ' -f1)"

# 清单与校验
say "=== 10) 校验清单 ==="
( cd "$A" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum > SHA256SUMS )
say "  + SHA256SUMS  $(wc -l < "$A/SHA256SUMS") 行"
say "=== 归档目录: $A  总大小 $(du -sh "$A" | cut -f1) ==="
