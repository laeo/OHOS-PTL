cd /data/log/hilog
echo "=== module_profile-level failures ==="
zcat hilog.*.gz 2>/dev/null | grep -a -E "applicationInfo failed|innerModuleInfo failed|g_parseResult|bad profile|TransformTo module|CheckBundleNameIsValid|module name is invalid|bundle name or module" | head -40
echo "=== base_bundle_installer parse ==="
zcat hilog.*.gz 2>/dev/null | grep -a "parse haps file failed" | head -30
echo "=== profile prop check ==="
zcat hilog.*.gz 2>/dev/null | grep -a -iE "not allow use privilege|not allow use system extension|not allow app share" | head -20
echo "=== SceneBoard surround (any file) ==="
zcat hilog.*.gz 2>/dev/null | grep -a -B8 "parse haps file failed 8519888" | head -40
echo "=== END ==="
