DB=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE/BUNDLE_INSTALL_EXCEPTION-1-MINOR-481-0.db
echo "=== strings with hex/context ==="
strings -n 4 "$DB" 2>/dev/null | grep -aE "SceneBoard|ERROR|VERSION|INSTALL_TYPE" | head -40
echo "=== hexdump around SceneBoard ==="
grep -abo "SceneBoard" "$DB" 2>/dev/null | head
echo "=== use od to find error code int ==="
python3 - <<'PYEOF'
import re
data = open('/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE/BUNDLE_INSTALL_EXCEPTION-1-MINOR-481-0.db','rb').read()
i = data.find(b'SceneBoard')
print('offset', i)
print(repr(data[max(0,i-200):i+400]))
PYEOF
echo "=== END ==="
