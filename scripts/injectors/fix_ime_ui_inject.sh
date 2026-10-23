#!/bin/bash
# fix_ime_ui/inject.sh
# Inject into the pc_ptl partdisk image (ONLY p2 / system):
#   - com.ohos.inputmethodchoosedialog  (rebuilt: always-dismissable dialog)
#   - SceneBoard                        (indicator: no left-click chooser, menu tuning)
#   - /system/etc/inputmethod/inputmethod_framework_config.json (IMF config ability)
# Leaves exactly one .zst whole-disk backup; never an uncompressed whole-disk copy.
set -e
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
IMG=$BASE/partdisk/media/ohos_part_pc_ptl.img
W=$BASE/fix_ime_ui
P2=$W/work/p2.img
BK=$BASE/partdisk/media/ohos_part_pc_ptl.pre_ime_ui.img.zst
DIALOG=$W/work/input_method_choose_dialog.hap
SCB=$BASE/porting/scb_src/product/pc/build/default/outputs/default/pc_sceneboard-default-signed.hap
CFG=$W/work/inputmethod_framework_config.json

echo "[0/7] stop qemu"
pkill -9 -f 'qemu-system-x86_64 -[m]achine' 2>/dev/null || true
sleep 1

echo "[1/7] sha256 before"
sha256sum "$IMG" | tee "$W/sha_before.txt"

if [ ! -f "$BK" ]; then
  echo "[2/7] backup -> $(basename "$BK")"
  zstd -T8 -3 -q -f "$IMG" -o "$BK"
  sha256sum "$BK" | tee "$W/backup_sha256.txt"
  ls -la "$BK"
else
  echo "[2/7] backup exists, reuse: $(ls -la "$BK" | awk '{print $5" bytes"}')"
fi

echo "[3/7] extract p2"
rm -f "$P2"
dd if="$IMG" of="$P2" bs=1M skip=513 count=2048 status=none

echo "[4/7] debugfs inject"
debugfs -w "$P2" 2>&1 <<EOF | grep -vE '^debugfs ' || true
mkdir /system/etc/inputmethod
rm /system/app/com.ohos.inputmethodchoosedialog/input_method_choose_dialog.hap
write $DIALOG /system/app/com.ohos.inputmethodchoosedialog/input_method_choose_dialog.hap
sif /system/app/com.ohos.inputmethodchoosedialog/input_method_choose_dialog.hap mode 0100644
sif /system/app/com.ohos.inputmethodchoosedialog/input_method_choose_dialog.hap uid 0
sif /system/app/com.ohos.inputmethodchoosedialog/input_method_choose_dialog.hap gid 0
rm /system/app/SceneBoard/SceneBoard.hap
write $SCB /system/app/SceneBoard/SceneBoard.hap
sif /system/app/SceneBoard/SceneBoard.hap mode 0100644
sif /system/app/SceneBoard/SceneBoard.hap uid 0
sif /system/app/SceneBoard/SceneBoard.hap gid 0
rm /system/etc/inputmethod/inputmethod_framework_config.json
write $CFG /system/etc/inputmethod/inputmethod_framework_config.json
sif /system/etc/inputmethod/inputmethod_framework_config.json mode 0100644
sif /system/etc/inputmethod/inputmethod_framework_config.json uid 0
sif /system/etc/inputmethod/inputmethod_framework_config.json gid 0
EOF

echo "[5/7] e2fsck p2"
e2fsck -f -y "$P2" > "$W/e2fsck_p2.log" 2>&1 || true
tail -2 "$W/e2fsck_p2.log"
debugfs -R 'stats' "$P2" 2>/dev/null | grep -i 'Free blocks' | head -1

echo "[6/7] write back p2"
dd if="$P2" of="$IMG" bs=1M seek=513 count=2048 conv=notrunc status=none
sync

echo "[7/7] readback verify"
rm -f "$W/work/rb_dlg.hap" "$W/work/rb_scb.hap" "$W/work/rb_cfg.json"
debugfs -R "dump /system/app/com.ohos.inputmethodchoosedialog/input_method_choose_dialog.hap $W/work/rb_dlg.hap" "$P2" 2>/dev/null
debugfs -R "dump /system/app/SceneBoard/SceneBoard.hap $W/work/rb_scb.hap" "$P2" 2>/dev/null
debugfs -R "dump /system/etc/inputmethod/inputmethod_framework_config.json $W/work/rb_cfg.json" "$P2" 2>/dev/null
OK=1
cmp -s "$DIALOG" "$W/work/rb_dlg.hap" && echo "OK dialog" || { echo "MISMATCH dialog"; OK=0; }
cmp -s "$SCB" "$W/work/rb_scb.hap" && echo "OK sceneboard" || { echo "MISMATCH sceneboard"; OK=0; }
cmp -s "$CFG" "$W/work/rb_cfg.json" && echo "OK imf config" || { echo "MISMATCH imf config"; OK=0; }
rm -f "$W/work/rb_dlg.hap" "$W/work/rb_scb.hap" "$W/work/rb_cfg.json"
echo "verify_ok=$OK"
sha256sum "$IMG" | tee "$W/new_sha256.txt"
ls -la "$IMG"