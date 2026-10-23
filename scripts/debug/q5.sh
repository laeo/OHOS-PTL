echo 1 > /proc/sys/kernel/printk
echo 0 > /proc/sys/kernel/printk_devkmsg
sleep 1
D=/data/log/hiview/sys_event_db/BUNDLEMANAGER_UE
F=$(ls -t $D/*INSTALL_EXCEPTION* 2>/dev/null | head -1)
base64 "$F" | tr -d '\n'
echo
echo __B64END__
