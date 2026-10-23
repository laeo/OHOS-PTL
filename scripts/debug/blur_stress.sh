#!/system/bin/sh
# Run in guest: toggle context menu repeatedly and snapshot each frame.
N=${1:-20}
i=1
while [ $i -le $N ]; do
  sh /data/local/tmp/inj.sh 400 300 right
  sleep 1
  snapshot_display -i 0 -f /data/local/tmp/st_$i.jpeg >/dev/null 2>&1
  sh /data/local/tmp/inj.sh 950 250 left
  sleep 1
  i=$((i+1))
done
echo "stress done $N"
