hilog -x > /data/h4.txt 2>&1
echo "=== total lines ==="
wc -l /data/h4.txt
echo "=== install-related warnings/errors ==="
grep -aiE "not supported|check.*fail|install.*fail|DEVICE_TYPE|syscap|Parse bundleDir" /data/h4.txt | grep -aiE "bms|bundle|install" | tail -40
echo "=== install_list read ==="
grep -aiE "install_list|PreInstall|preinstall" /data/h4.txt | grep -ai bms | tail -20
echo "=== done ==="
