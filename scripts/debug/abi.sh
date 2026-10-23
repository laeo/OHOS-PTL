{
echo "=== abi params ==="
param get const.product.cpu.abilist 2>&1
param get const.product.cpu.abi 2>&1
param get const.bms.abi 2>&1
param get persist.sys.ohos.cpu.abilist 2>&1
echo "=== system lib64 ==="
ls -d /system/lib64 2>&1
echo "=== settings.hap check ==="
} > /data/abi.txt 2>&1
echo DONE_ABI
