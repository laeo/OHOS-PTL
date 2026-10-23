D=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE
for f in $(ls -t $D/*INSTALL_EXCEPTION* 2>/dev/null); do
  echo "=== $f ==="
  strings -n 6 "$f" | grep -a "^/.*app/" | sort -u
done
echo "=== privilege errors in current ring ==="
hilog -x 2>/dev/null | grep -a -E "not allow use privilege|parse haps file failed|8519888" | tail -20
echo "=== END ==="
