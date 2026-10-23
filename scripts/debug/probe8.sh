hilog -x > /data/h5.txt 2>&1
echo "=== LINES ==="
wc -l /data/h5.txt
echo "=== INSTALLER tag lines ==="
grep -a "INSTALLER\|installer" /data/h5.txt | tail -40
echo "=== moduleName supports ==="
grep -a "moduleName" /data/h5.txt | tail -30
echo "=== boot install ==="
grep -a -iE "boot install|PreInstall|preinstall|scan" /data/h5.txt | tail -30
echo "=== END ==="
