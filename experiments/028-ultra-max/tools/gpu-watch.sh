#!/bin/zsh
# Lead watch on the Studio GPU sampler (gpu-util.sh, started there detached). Runs on the laptop. One line per event:
#   IDLE-HELD  a lease holder kept the GPU under 10% for the last 60 s (once per hold)
#   STALL      no holder while tickets wait, for the last 60 s (once per queue episode)
#   LOG-STALE  gpu-util.log not written for over 90 s (sampler died)
#   SSH-FAIL   three polls in a row could not reach the Studio
#   EMPTY      no holder and an empty queue for 5 min (once per idle episode): the pipeline has stalled
. "${0:A:h}/../hosts.env"
log=/tmp/openmm-metal-bench/ultra-lead/gpu-util.log
seen=""
fails=0
empty=0
note() {
    grep -qxF -- "$1" <<<"$seen" && return
    seen="$seen"$'\n'"$1"
    echo "$(date -u +%H:%M:%SZ) $2"
}
while true; do
    out=$(timeout 25 ssh -o ConnectTimeout=10 "$STUDIO" \
        "date +%s; stat -f %m $log; tail -12 $log; echo OWNER; head -c 110 /tmp/openmm-lease/owner 2>/dev/null" 2>/dev/null)
    if [ -z "$out" ]; then
        fails=$((fails + 1))
        [ $fails -eq 3 ] && echo "$(date -u +%H:%M:%SZ) SSH-FAIL 3 polls in a row"
        sleep 30
        continue
    fi
    fails=0
    now=$(sed -n 1p <<<"$out")
    mtime=$(sed -n 2p <<<"$out")
    util=$(sed -n '3,/^OWNER$/p' <<<"$out" | grep -v '^OWNER$')
    owner=$(sed -n '/^OWNER$/,$p' <<<"$out" | sed 1d | tr '\n' ' ')
    last=$(tail -1 <<<"$util")
    holder=$(awk '{print $3}' <<<"$last")
    queue=$(awk '{print $4}' <<<"$last")
    busy=$(awk '{split($2,g,"="); if (g[2]+0 >= 10) b++} END {print b+0}' <<<"$util")
    free_waits=$(awk '$3 == "holder=none" && $4 != "queue=0" {n++} END {print n+0}' <<<"$util")
    lines=$(wc -l <<<"$util" | tr -d ' ')
    if [ "$holder" = "holder=none" ] && [ "$queue" = "queue=0" ]; then
        empty=$((empty + 1))
        [ $empty -eq 10 ] && echo "$(date -u +%H:%M:%SZ) EMPTY 5 min: GPU free and nothing queued"
    else
        empty=0
    fi
    if [ $((now - mtime)) -gt 90 ]; then
        note "stale-$mtime" "LOG-STALE gpu-util.log last written $((now - mtime))s ago"
    elif [ "$holder" != "holder=none" ] && [ "$busy" -eq 0 ] && [ "$lines" -ge 12 ]; then
        note "held-$owner" "IDLE-HELD 60s gpu<10% $holder $queue owner: $owner"
    elif [ "$free_waits" -ge 12 ]; then
        note "stall-$(awk '{print $1}' <<<"$(head -1 <<<"$util")" | cut -c1-4)" "STALL 60s no holder with $queue waiting"
    fi
    sleep 30
done
