echo "=== exception paths (current) ==="
for f in $(ls -t /data/log/hiview/sys_event_db/BUNDLEMANAGER_UE/*INSTALL_EXCEPTION* 2>/dev/null | head -1); do
  strings -n 6 "$f" | grep -a "^/system/app" | sort -u
done
echo "=== capability file has 8E93 for scene? ==="
grep -c 8E93863FC32EE238060BF69A9B37E2608FFFB21F93C862DD511CBAC9F30024B5 /system/etc/app/install_list_capability.json
grep -c 0716E4E8 /system/etc/app/install_list_capability.json
echo "=== count installed ==="
ls /data/app/el1/bundle/public | wc -l
echo "=== END ==="
