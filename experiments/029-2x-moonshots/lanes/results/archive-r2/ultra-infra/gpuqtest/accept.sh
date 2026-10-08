#!/bin/sh
# gpuq acceptance checks 1-5 and 7 in an isolated instance (own socket, state, lease mirrors), fake jobs
# only, no GPU work. The build gap cap is 20 s here in place of 900 and the SIGKILL grace 5 s in place of
# 30; the logic is the same. Check 6 (ab.sh and window.sh through the shim) needs the GPU: accept6.sh.
# usage: accept.sh [check...]   (default: 1 2 3 4 5 7)
T=/tmp/openmm-metal-bench/ultra-infra/gpuqtest
. $T/env.sh
export GPUQ_KILL_GRACE=5
DB=$GPUQ_DIR/state.db
checks="${*:-1 2 3 4 5 7}"
fail=0

fresh() {
    [ -z "${daemon:-}" ] || { kill "$daemon" 2>/dev/null; wait "$daemon" 2>/dev/null; }
    rm -rf $GPUQ_DIR $GPUQ_LEASE_DIR $GPUQ_QUEUE_DIR $GPUQ_SOCK
    start_daemon
}
sql() { $PY -c "import sqlite3,sys; c=sqlite3.connect('$DB'); [print(*r) for r in c.execute(sys.argv[1])]" "$1"; }
ok() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; fail=1; }
check() { if [ "$1" = "$2" ]; then ok "$3: $1"; else bad "$3: got '$1', want '$2'"; fi; }
sub() { $Q submit "$@" | sed -n 's/^job \([0-9]*\) queued.*/\1/p'; }
idle() { while [ -n "$(sql "select id from jobs where state != 'ended'")" ]; do sleep 0.5; done; }
order() { sql "select lane from jobs where started is not null order by started, id" | tr '\n' ' ' | sed 's/ $//'; }

for c in $checks; do case $c in
1)
    for slot in day night; do
        echo "== 1 ($slot): priority merge > window > correctness > timing by day (timing above correctness at night), round-robin across lanes"
        export GPUQ_SLOT=$slot; fresh
        sub --lane z --est 3 -- sleep 3 > /dev/null
        sleep 0.5
        for l in a a a b; do sub --lane $l --est 1 -- sleep 1 > /dev/null; done
        sub --lane c --class correctness --est 1 -- sleep 1 > /dev/null
        sub --lane c2 --class correctness --est 1 -- sleep 1 > /dev/null
        sub --lane m --class merge --est 1 -- sleep 1 > /dev/null
        sub --lane w --class window --est 1 -- sleep 1 > /dev/null
        idle
        if [ $slot = day ]; then want="z m w c c2 a b a a"; else want="z m w a b a a c c2"; fi
        check "$(order)" "$want" "start order"
        together=$(sql "select a.started < b.ended and b.started < a.ended from jobs a, jobs b where a.lane = 'c' and b.lane = 'c2'")
        check "$together" 1 "the two correctness jobs ran at the same time"
    done
    export GPUQ_SLOT=day
    ;;
2)
    echo "== 2: window reservation: a timing job that would overrun waits, a short one backfills"
    fresh
    sub --lane w --class window --not-before +15s --est 3 -- sleep 3 > /dev/null
    sub --lane long --est 30 -- sleep 1 > /dev/null
    sub --lane short --est 8 -- sleep 8 > /dev/null
    idle
    check "$(order)" "short w long" "start order"
    late=$(sql "select round(started - not_before, 1) from jobs where lane = 'w'")
    awk -v l="$late" 'BEGIN { exit !(l >= 0 && l <= 1.5) }' && ok "window started ${late} s after its not-before" || bad "window started ${late} s after its not-before"
    ;;
3)
    echo "== 3: builds stopped and continued by group and descendants around timing jobs; the gap and its cap (20 s here)"
    fresh
    B=$T/build3; rm -rf $B; mkdir -p $B
    # A ninja build like build.sh's: two endless jobs, each in its own process group, ticking once a second.
    printf 'rule tick\n  command = sh -c "while :; do date +%%s >> %s/ticks.$out; sleep 1; done"\nbuild j1: tick\nbuild j2: tick\n' $B > $B/build.ninja
    (cd $B && $Q hold --class build --lane bld --what "fake build" -- /tmp/openmm-metal-bench/env/bin/ninja -j 2 > /dev/null 2>&1) &
    client=$!
    sleep 3
    ticks() { cat $B/ticks.j1 $B/ticks.j2 2>/dev/null | wc -l | tr -d ' '; }
    states() { pg=$(sql "select pgid from jobs where lane = 'bld'"); ps -axo pgid=,ppid=,pid=,stat=,command= | awk -v g="$pg" '$1 == g || $0 ~ /ticks\.j/' | grep -v awk | awk '{ print substr($4, 1, 1) }' | sort | uniq -c | tr -s ' ' | tr '\n' ' '; }
    echo "  build running: $(states)"
    sub --lane t1 --est 5 -- sleep 5 > /dev/null
    sleep 2
    s1=$(states); n1=$(ticks); sleep 2; n2=$(ticks)
    case "$s1" in *" R "*|*" S "*) bad "processes still running during timing: $s1" ;; *) ok "during timing every build process is stopped: $s1" ;; esac
    check "$((n2 - n1))" 0 "ticks added in 2 s during timing"
    sub --lane t2 --est 2 -- sleep 2 > /dev/null
    while [ "$(sql "select state from jobs where lane = 't1'")" != ended ]; do sleep 0.2; done
    sleep 2
    s2=$(states); n3=$(ticks); sleep 2; n4=$(ticks)
    case "$s2" in *" T "*) bad "processes still stopped after timing: $s2" ;; *) ok "after timing, the build runs again: $s2" ;; esac
    [ $((n4 - n3)) -ge 2 ] && ok "ticks resume: $((n4 - n3)) in 2 s" || bad "ticks after timing: $((n4 - n3))"
    while [ "$(sql "select state from jobs where lane = 't2'")" = queued ]; do sleep 0.2; done
    gap=$(sql "select cast(round(t2.started - t1.ended) as int) from jobs t1, jobs t2 where t1.lane = 't1' and t2.lane = 't2'")
    [ "$gap" -ge 20 ] && [ "$gap" -le 22 ] && ok "the endless build got the 20 s gap cap before t2: ${gap} s" || bad "gap before t2: ${gap} s"
    sleep 1; s3=$(states)
    case "$s3" in *" R "*|*" S "*) bad "t2 didn't pause the build: $s3" ;; *) ok "t2 paused the build again: $s3" ;; esac
    idle_t2() { while [ "$(sql "select state from jobs where lane = 't2'")" != ended ]; do sleep 0.2; done; }
    idle_t2
    $Q cancel "$(sql "select id from jobs where lane = 'bld'")" --lane bld > /dev/null
    wait $client
    check "$(sql "select reason from jobs where lane = 'bld'")" cancelled "build cancelled"
    left=$(ps -axo command= | grep -c "ticks\.j" | tr -d ' ')
    check "$left" 0 "tick processes left after the cancel"
    echo "  -- a build that ends inside the gap: the next timing job starts when it ends"
    fresh
    (cd $T && $Q hold --class build --lane bld2 --what "short build" -- sh -c 'sleep 8' > /dev/null 2>&1) &
    client=$!
    sleep 1
    sub --lane t3 --est 2 -- sleep 2 > /dev/null
    sleep 0.5
    sub --lane t4 --est 1 -- sleep 1 > /dev/null
    idle; wait $client
    after=$(sql "select round(t4.started - b.ended, 1) from jobs b, jobs t4 where b.lane = 'bld2' and t4.lane = 't4'")
    held=$(sql "select round(b.ended - t3.ended, 1) from jobs b, jobs t3 where b.lane = 'bld2' and t3.lane = 't3'")
    awk -v a="$after" -v h="$held" 'BEGIN { exit !(a >= 0 && a <= 1.5 && h > 3) }' && ok "t4 waited ${held} s for the build and started ${after} s after it ended" || bad "t4 start ${after} s after the build end, held ${held} s"
    grep -h 'build gap' $GPUQ_DIR/../daemon.log | tail -4 | sed 's/^/    /'
    ;;
4)
    echo "== 4: the cap kills only the job's process group (SIGTERM, then SIGKILL after the grace)"
    fresh
    sleep 300 & bystander=$!
    sub --lane k --est 1 --cap 3 -- sh -c 'sleep 300 & sleep 300' > /dev/null
    sub --lane k2 --est 1 --cap 3 -- sh -c 'trap "" TERM; sleep 300 & wait' > /dev/null
    idle
    sql "select lane, reason, exit_code, round(ended - started, 1) from jobs order by id" | sed 's/^/    /'
    check "$(sql "select reason || ' ' || exit_code from jobs where lane = 'k'")" "cap 143" "k (dies on SIGTERM)"
    k2=$(sql "select reason || ' ' || exit_code || ' ' || cast(round(ended - started) as int) from jobs where lane = 'k2'")
    case "$k2" in "cap 137 "8|"cap 137 "9) ok "k2 (ignores SIGTERM): $k2 s, SIGKILL after the 5 s grace" ;; *) bad "k2: $k2" ;; esac
    kill -0 $bystander 2>/dev/null && ok "a bystander sleep outside the job is alive" || bad "bystander killed"
    kill $bystander
    left=$(ps -axo command= | grep -c '^sleep 300$')
    check "$left" 0 "sleeps of the capped jobs left"
    ;;
5)
    echo "== 5: kill -9 of the daemon during running jobs; after a restart they are reattached and their exit codes recorded"
    fresh
    sub --lane r --est 6 -- sh -c 'sleep 6; exit 7' > /dev/null
    (GPUQ_LANE=r2 $Q hold --class correctness --what attached -- sh -c 'sleep 6; exit 5' > $T/hold5.out 2>&1; echo "client exit $?" >> $T/hold5.out) &
    client=$!
    sleep 2
    kill -9 $daemon; wait $daemon 2>/dev/null
    echo "  daemon $daemon killed with SIGKILL; restarting in 2 s"
    sleep 2
    start_daemon
    wait $client
    idle
    grep -h reattached $T/daemon.log | tail -2 | sed 's/^/    /'
    check "$(sql "select reason || ' ' || exit_code from jobs where lane = 'r'")" "exit 7" "managed job"
    check "$(sql "select reason || ' ' || exit_code from jobs where lane = 'r2'")" "exit 5" "attached hold"
    check "$(tail -1 $T/hold5.out)" "client exit 5" "attached client"
    ;;
7)
    echo "== 7: gpuq ls shows elapsed and predicted start for 4 lanes"
    fresh
    sub --lane lane-a --est 10 -- sleep 10 > /dev/null
    sleep 2
    sub --lane lane-b --est 6 -- sleep 6 > /dev/null
    sub --lane lane-c --class correctness --est 4 -- sleep 4 > /dev/null
    sub --lane lane-d --est 5 -- sleep 5 > /dev/null
    sub --lane lane-b --est 3 -- sleep 3 > /dev/null
    sleep 1
    $Q ls | sed 's/^/    /'
    $Q ls | sed -n 's/^ *[0-9]*\. *\([0-9]*\) .*starts \([0-9:]*Z\).*/\1 \2/p' > $T/predicted7
    idle
    while read id at; do
        actual=$(sql "select strftime('%H:%M:%SZ', started, 'unixepoch') from jobs where id = $id")
        d=$($PY -c "import sys; a,b=[int(x[:2])*3600+int(x[3:5])*60+int(x[6:8]) for x in sys.argv[1:]]; print(b-a)" "$at" "$actual")
        [ "${d#-}" -le 2 ] && ok "job $id predicted $at, started $actual" || bad "job $id predicted $at, started $actual"
    done < $T/predicted7
    ;;
esac; done
[ -z "${daemon:-}" ] || kill "$daemon" 2>/dev/null
echo "result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
