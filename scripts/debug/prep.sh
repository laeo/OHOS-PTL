hilog -w start 2>&1
hilog -w query 2>&1 | head -3
hilog -b D 2>&1
sync
echo PREP_DONE
