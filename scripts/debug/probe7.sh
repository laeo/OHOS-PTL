echo "=== try bm install ==="
bm install -p /system/app/SceneBoard/SceneBoard.hap -u 100 2>&1 | head -30
echo "=== try aa start ==="
aa start -b com.ohos.sceneboard -a com.ohos.sceneboard.MainAbility 2>&1 | head -10
echo "=== END ==="
