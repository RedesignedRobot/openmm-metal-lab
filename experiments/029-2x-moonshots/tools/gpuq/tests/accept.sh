#!/bin/sh
# gpuq acceptance checks 1-5 and 7 in an isolated instance (own socket, state, lease mirrors), fake jobs
# only, no GPU work. The build gap cap is 20 s here in place of 900 and the SIGKILL grace 5 s in place of
# 30; the logic is the same. Check 6 (ab.sh and window.sh through the shim) needs the GPU: accept6.sh.
# Checks 8-11 cover the review of 3ba9025: groups drain before a job ends, gpuq off, crashes during a
# launch or a pause, and nested leases. Checks 12-14 cover round 3's declarative night: --not-before on
# any class, --not-after expiry, the window --est rule and its default cap, --after skipping on a failed
# dependency, and the end reasons that tell a kill (who sent it) from an exit code. Check 15 is the night
# hold (2026-09-30): with a timing job queued at night, an ad hoc build opens no gap that correctness backfills.
# Check 16: a queued build whose not-before is later opens no gap, in the daemon or in the prediction.
# Check 17: a build --after a queued correctness job opens no gap (the 07:21Z idle cycle with the starve rule).
# usage: accept.sh [check...]   (default: 1 2 3 4 5 7 8 9 10 11 12 13 14 15 16 17)
. "$(dirname "$0")/env.sh"
export GPUQ_KILL_GRACE=5
DB=$GPUQ_DIR/state.db
checks="${*:-1 2 3 4 5 7 8 9 10 11 12 13 14 15 16 17}"
fail=0

fresh() {
    [ -z "${daemon:-}" ] || { kill "$daemon" 2>/dev/null; wait "$daemon" 2>/dev/null; }
    rm -rf $GPUQ_DIR $GPUQ_LEASE_DIR $GPUQ_QUEUE_DIR $GPUQ_SOCK
    start_daemon
}
sql() { $PY -c "import sqlite3,sys; c=sqlite3.connect('$DB'); [print(*r) for r in c.execute(sys.argv[1])]; c.commit()" "$1"; }
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
    # The ninja is a copy named tickbuild: ab-test.sh's build scan matches the name ninja, and this test
    # runs by day beside real timing holds (it marked r2-accum-nb's cellulose row on 2026-09-28).
    cp -p /tmp/openmm-metal-bench/env/bin/ninja $T/tickbuild
    printf 'rule tick\n  command = sh -c "while :; do date +%%s >> %s/ticks.$out; sleep 1; done"\nbuild j1: tick\nbuild j2: tick\n' $B > $B/build.ninja
    (cd $B && $Q hold --class build --lane bld --what "fake build" -- $T/tickbuild -j 2 > /dev/null 2>&1) &
    client=$!
    sleep 3
    check "$(sql "select pgid is not null and submitted <= started from jobs where lane = 'bld'")" 1 "the build's group was on record at submit, before its grant"
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
8)
    echo "== 8: a job keeps the GPU until its process group drains"
    fresh
    sub --lane d1 --est 1 --cap 3 -- sh -c 'sh -c "trap \"\" TERM; sleep 300" & wait' > /dev/null
    sleep 0.5
    sub --lane d2 --est 1 -- sleep 1 > /dev/null
    idle
    sql "select lane, reason, exit_code, round(started, 1), round(ended, 1) from jobs order by id" | sed 's/^/    /'
    check "$(sql "select reason from jobs where lane = 'd1'")" cap "d1: its shell died on SIGTERM, the child that ignores it kept the job"
    ran=$(sql "select cast(round(ended - started) as int) from jobs where lane = 'd1'")
    [ "$ran" -ge 8 ] && [ "$ran" -le 10 ] && ok "d1 ended ${ran} s after its start: 3 s cap, 5 s grace, then SIGKILL" || bad "d1 ran ${ran} s"
    check "$(sql "select d2.started >= d1.ended from jobs d1, jobs d2 where d1.lane = 'd1' and d2.lane = 'd2'")" 1 "d2 started only after d1's group was gone"
    (GPUQ_LANE=d3 $Q hold --est 30 -- sh -c 'trap "" TERM; sleep 300' > /dev/null 2>&1) &
    client=$!
    while [ "$(sql "select state from jobs where lane = 'd3'")" != running ]; do sleep 0.2; done
    sub --lane d4 --est 1 -- sleep 1 > /dev/null
    hold_pid=$(sql "select client_pid from jobs where lane = 'd3'")
    killed=$($PY -c 'import time; print(time.time())')
    kill -9 $hold_pid; wait $client 2>/dev/null
    idle
    check "$(sql "select reason from jobs where lane = 'd3'")" lost "d3: its client got SIGKILL"
    late=$(sql "select round(ended - $killed, 1) from jobs where lane = 'd3'")
    awk -v l="$late" 'BEGIN { exit !(l >= 5 && l <= 7.5) }' && ok "d3's group (ignores SIGTERM) held the GPU ${late} s after its client died, then SIGKILL" || bad "d3 ended ${late} s after its client died"
    check "$(sql "select d4.started >= d3.ended from jobs d3, jobs d4 where d3.lane = 'd3' and d4.lane = 'd4'")" 1 "d4 started only after d3's group was gone"
    check "$(ps -axo command= | grep -c '^sleep 300$' | tr -d ' ')" 0 "sleeps left"
    ;;
9)
    echo "== 9: gpuq off drains, continues the paused build, then writes OFF; queued leases fall back; legacy sees gpuq holders"
    fresh
    printf '#!/bin/sh\necho "legacy lease.sh $*"\n' > $T/fake-legacy.sh; chmod +x $T/fake-legacy.sh
    (cd $T && $Q hold --class build --lane b9 --what "build.sh b9" -- sh -c 'while :; do sleep 1; done' > /dev/null 2>&1) &
    bclient=$!
    while [ "$(sql "select state from jobs where lane = 'b9'")" != running ]; do sleep 0.2; done
    (GPUQ_LANE=t9 $Q hold --est 6 -- sleep 6 > /dev/null 2>&1) &
    tclient=$!
    while [ "$(sql "select state from jobs where lane = 't9'")" != running ]; do sleep 0.2; done
    eval "$(sed -n '/^is_lease_pid() {/,/^}/p' $D/../lease-legacy.sh)"
    is_lease_pid "$(cat $GPUQ_LEASE_DIR/pid)" && ok "lease-legacy.sh counts the gpuq holder in /tmp/openmm-lease (pid $(cat $GPUQ_LEASE_DIR/pid)) as live" || bad "lease-legacy.sh doesn't see the gpuq holder"
    (GPUQ_LEGACY_LEASE=$T/fake-legacy.sh $Q lease lane9 "queued lease" true > $T/lease9.out 2>&1) &
    lclient=$!
    sleep 1
    $Q off > $T/off9.out
    offdone=$($PY -c 'import time; print(time.time())')
    sed 's/^/    /' $T/off9.out
    check "$(sql "select ended <= $offdone from jobs where lane = 't9'")" 1 "gpuq off returned after the running timing job ended"
    [ -e $GPUQ_DIR/OFF ] && ok "OFF written" || bad "no OFF"
    bpg=$(sql "select pgid from jobs where lane = 'b9'")
    check "$(ps -axo pgid=,stat= | awk -v g=$bpg '$1 == g { print substr($2, 1, 1) }' | grep -c T | tr -d ' ')" 0 "processes of the build left stopped"
    wait $lclient
    check "$(grep -c '^legacy lease.sh lane9 queued lease true$' $T/lease9.out | tr -d ' ')" 1 "the queued lease ran lease-legacy.sh with its own arguments"
    check "$(sql "select reason from jobs where lane = 'lane9'")" off "the queued lease's job"
    $Q submit --lane x -- true > /dev/null 2>&1 && bad "a submit while off was accepted" || ok "a submit while off is refused"
    $Q on > /dev/null
    [ ! -e $GPUQ_DIR/OFF ] && ok "gpuq on removed OFF" || bad "OFF still there"
    $Q cancel "$(sql "select id from jobs where lane = 'b9'")" --lane b9 > /dev/null
    wait $bclient $tclient
    ;;
10)
    echo "== 10: crashes during a launch and during a pause"
    fresh
    # A stale socket file would let start_daemon return before the new daemon listens.
    restart() { kill $daemon 2>/dev/null; wait $daemon 2>/dev/null; rm -f $GPUQ_SOCK; GPUQ_CRASH_AT=$1; export GPUQ_CRASH_AT; start_daemon; unset GPUQ_CRASH_AT; }
    restart launch
    sub --lane c10 --est 3 -- sh -c 'echo ran; sleep 3; exit 4' > /dev/null 2>&1  # the daemon dies before it answers
    wait $daemon 2>/dev/null
    check "$(sql "select state from jobs where lane = 'c10'")" launching "row state after the daemon died between Popen and running"
    restart ''
    idle
    grep -h 'adopted job' $T/daemon.log | tail -1 | sed 's/^/    /'
    check "$(sql "select reason || ' ' || exit_code from jobs where lane = 'c10'")" "exit 4" "the adopted job's exit"
    check "$(grep -c '^ran$' $GPUQ_DIR/jobs/1/out.log | tr -d ' ')" 1 "times the job ran"
    restart pause
    (cd $T && $Q hold --class build --lane b10 -- sh -c 'while :; do date +%s >> '$T'/ticks10; sleep 1; done' > /dev/null 2>&1) &
    bclient=$!
    while [ "$(sql "select state from jobs where lane = 'b10'")" != running ]; do sleep 0.2; done
    sub --lane t10 --est 2 -- sleep 2 > /dev/null 2>&1
    wait $daemon 2>/dev/null
    bpg=$(sql "select pgid from jobs where lane = 'b10'")
    echo "    after the crash: paused=$(sql "select paused from jobs where lane = 'b10'"), group $bpg states $(ps -axo pgid=,stat= | awk -v g=$bpg '$1 == g { print substr($2, 1, 1) }' | tr '\n' ' ')"
    # The timing job ends before the restart, so no tick would pause (and continue) the build again.
    sql "update jobs set state = 'ended', reason = 'cancelled' where lane = 't10'" > /dev/null
    restart ''
    sleep 2
    n1=$(wc -l < $T/ticks10); sleep 2; n2=$(wc -l < $T/ticks10)
    [ $((n2 - n1)) -ge 1 ] && ok "the restarted daemon continued the build it had stopped: $((n2 - n1)) ticks in 2 s" || bad "build still stopped after the restart"
    $Q cancel "$(sql "select id from jobs where lane = 'b10'")" --lane b10 > /dev/null
    wait $bclient
    rm -f $T/ticks10
    ;;
11)
    echo "== 11: a lease inside a build job queues for the GPU"
    fresh
    (cd $T && $Q hold --class build --lane b11 -- $Q lease --correctness lane11 "nested in a build" true > /dev/null 2>&1)
    check "$(sql "select cls || ' ' || reason || ' ' || exit_code from jobs where lane = 'lane11'")" "correctness exit 0" "the lease inside the build got its own correctness job"
    ;;
12)
    echo "== 12: --not-before on timing and correctness jobs, --not-after expiry, the window --est rule and cap"
    fresh
    sub --lane nbt --not-before +4s --est 1 -- true > /dev/null
    sub --lane nbc --class correctness --not-before +4s --est 1 -- true > /dev/null
    sleep 1
    $Q ls | sed 's/^/    /'
    check "$(sql "select count(*) from jobs where started is not null")" 0 "jobs started before their not-before on an idle GPU"
    idle
    for l in nbt nbc; do
        late=$(sql "select round(started - not_before, 1) from jobs where lane = '$l'")
        awk -v l="$late" 'BEGIN { exit !(l >= 0 && l <= 1.5) }' && ok "$l started ${late} s after its not-before" || bad "$l started ${late} s after its not-before"
    done
    fresh
    sub --lane blk --est 6 -- sleep 6 > /dev/null
    sub --lane exp --not-after +3s --est 1 -- true > /dev/null
    (GPUQ_LANE=exph $Q hold --not-after +3s --est 1 -- true > $T/hold12.out 2>&1; echo "client exit $?" >> $T/hold12.out) &
    client=$!
    idle; wait $client
    check "$(sql "select reason || ' ' || (started is null) from jobs where lane = 'exp'")" "expired 1" "a managed job behind a busy GPU past its not-after"
    check "$(sql "select reason from jobs where lane = 'exph'")" expired "an attached hold past its not-after"
    check "$(tail -1 $T/hold12.out)" "client exit 1" "the expired hold's client"
    sql "select lane, reason, note from jobs where lane like 'exp%'" | sed 's/^/    /'
    out=$($Q submit --lane x --not-after +1s --not-before +2s -- true 2>&1) && bad "not-after before not-before accepted" || ok "not-after before not-before refused: $out"
    out=$($Q submit --lane w --class window --not-before +1h -- true 2>&1) && bad "a window without --est accepted" || ok "a window without --est refused: $out"
    out=$($Q submit --lane w --class window --not-before +1h --est 60 -- true)
    echo "    $out"
    check "$(sql "select cast(cap as int) from jobs where lane = 'w'")" 1320 "a 60 s window's default cap (2 x est + 20 min)"
    $Q status "$(sql "select id from jobs where lane = 'w'")" | grep '^cap:' | sed 's/^/    /'
    $Q cancel "$(sql "select id from jobs where lane = 'w'")" --lane w > /dev/null
    ;;
13)
    echo "== 13: --after runs a job only after its dependency exited 0; a failed one skips the chain"
    fresh
    out=$($Q submit --lane x --after 99 -- true 2>&1) && bad "--after an unknown job accepted" || ok "--after an unknown job refused: $out"
    a=$(sub --lane a --est 1 -- sh -c 'sleep 1; exit 3')
    b=$(sub --lane b --after $a --est 1 -- true)
    sub --lane c --after $b --est 1 -- true > /dev/null
    k=$(sub --lane k --est 1 --cap 2 -- sleep 30)
    sub --lane e --after $k --est 1 -- true > /dev/null
    good=$(sub --lane good --est 1 -- sleep 1)
    sub --lane d --after $good --est 1 -- true > /dev/null
    idle
    sql "select lane, reason, exit_code, note from jobs order by id" | sed 's/^/    /'
    check "$(sql "select reason || ' ' || note from jobs where lane = 'b'")" "skipped dep $a failed: exit, exit 3" "after a job that exited 3"
    check "$(sql "select reason || ' ' || note from jobs where lane = 'c'")" "skipped dep $b failed: skipped" "after a skipped job"
    check "$(sql "select reason || ' ' || note from jobs where lane = 'e'")" "skipped dep $k failed: cap, exit 143" "after a capped job"
    check "$(sql "select d.reason || ' ' || d.exit_code || ' ' || (d.started >= g.ended) from jobs d, jobs g where d.lane = 'd' and g.lane = 'good'")" "exit 0 1" "after a job that exited 0: ran, once it ended"
    ;;
14)
    echo "== 14: the end reason tells a kill, and who sent it, from an exit code"
    fresh
    sub --lane x143 --est 1 -- sh -c 'exit 143' > /dev/null
    idle
    m=$(sub --lane m --est 30 -- sh -c 'sleep 30')
    while [ "$(sql "select state from jobs where id = $m")" != running ]; do sleep 0.2; done
    sleep 0.5
    work=$(pgrep -P "$(sql "select pid from jobs where id = $m")")
    kill -TERM $work
    (GPUQ_LANE=h $Q hold --est 30 -- sleep 30 > /dev/null 2>&1; echo "client exit $?" > $T/hold14.out) &
    client=$!
    while [ "$(sql "select state from jobs where lane = 'h'")" != running ]; do sleep 0.2; done
    sleep 0.5
    kill -TERM "$(sql "select client_pid from jobs where lane = 'h'")"
    wait $client
    sub --lane cap --est 1 --cap 2 -- sleep 30 > /dev/null
    idle
    check "$(sql "select reason || ' ' || exit_code || ' ' || ifnull(note, '-') from jobs where lane = 'x143'")" "exit 143 -" "a command that exits 143 by itself"
    check "$(sql "select reason || ' ' || exit_code || ' ' || note from jobs where lane = 'm'")" "killed 143 SIGTERM from outside gpuqd" "a managed job's command killed by pid"
    hn=$(sql "select reason || ' ' || exit_code || ' ' || note from jobs where lane = 'h'")
    case "$hn" in "killed 143 SIGTERM forwarded as SIGTERM by hold client "*", which got SIGTERM") ok "a hold whose client got SIGTERM: $hn" ;; *) bad "hold client killed: $hn" ;; esac
    check "$(cat $T/hold14.out)" "client exit 143" "the killed hold's client"
    check "$(sql "select reason || ' ' || exit_code || ' ' || note from jobs where lane = 'cap'")" "cap 143 gpuqd sent SIGTERM at the 2 s cap, the work died of SIGTERM" "a capped job"
    $Q history | sed 's/^/    /'
    ;;
15)
    echo "== 15: at night, with a timing job queued, an ad hoc build opens no gap that correctness backfills"
    export GPUQ_SLOT=night; fresh
    sub --lane a --est 3 -- sleep 3 > /dev/null
    sleep 0.5
    sub --lane b --est 1 -- sleep 1 > /dev/null
    sub --lane c --class correctness --est 1 -- sleep 1 > /dev/null
    sub --lane d --class build --est 1 -- sleep 1 > /dev/null
    idle
    sql "select id, lane, cls, round(started - submitted, 1), round(ended - submitted, 1) from jobs order by id" | sed 's/^/    /'
    check "$(order)" "a b c d" "start order"
    late=$(sql "select round(b.started - a.ended, 1) from jobs a, jobs b where a.lane = 'a' and b.lane = 'b'")
    awk -v l="$late" 'BEGIN { exit !(l >= 0 && l <= 1.5) }' && ok "timing b started ${late} s after a ended, through the build gap" || bad "timing b started ${late} s after a ended"
    check "$(sql "select count(*) from jobs j, jobs b where j.lane in ('c', 'd') and b.lane = 'b' and j.started >= b.ended")" 2 "correctness and the build started after timing b ended"
    grep -h 'build gap' $T/daemon.log | tail -2 | sed 's/^/    /'
    export GPUQ_SLOT=day
    ;;
16)
    echo "== 16: a queued build whose not-before is later opens no gap: timing follows timing at once, and predict says so"
    export GPUQ_SLOT=day; fresh
    gaps_before=$(grep -c 'build gap after job' $T/daemon.log)
    a=$(sub --lane a --est 3 -- sleep 3)
    sleep 0.5
    d=$(sub --lane d --class build --not-before +1h --est 60 -- true)   # est over the 20 s test gap, so predict would show a gap
    b=$(sub --lane b --est 1 -- sleep 1)
    sleep 0.5
    ahead=$($Q ls | awk -v b=$b '$2 == b' | sed -n 's/.*starts [^ ]* (+\([0-9]*\)s).*/\1/p')
    [ -n "$ahead" ] && [ "$ahead" -le 5 ] && ok "predicted start of timing b: +${ahead} s, no gap" || bad "predicted start of timing b: +${ahead:-?} s (a gap adds $GPUQ_GAP_SECONDS)"
    $Q wait $b > /dev/null
    late=$(sql "select round(b.started - a.ended, 1) from jobs a, jobs b where a.id = $a and b.id = $b")
    awk -v l="$late" 'BEGIN { exit !(l >= 0 && l <= 1.5) }' && ok "timing b started ${late} s after a ended" || bad "timing b started ${late} s after a ended"
    gaps=$(( $(grep -c 'build gap after job' $T/daemon.log) - gaps_before ))
    [ "$gaps" = 0 ] && ok "the daemon opened no gap after job $a" || bad "the daemon opened $gaps gap(s) for the future build: $(grep 'build gap after job' $T/daemon.log | tail -1)"
    $Q cancel $d --lane d > /dev/null
    ;;
17)
    echo "== 17: a build --after a queued correctness job opens no gap: timing follows that correctness job at once"
    export GPUQ_SLOT=day; fresh
    a=$(sub --lane a --est 3 -- sleep 3)
    gaps_before=$(grep -c "build gap after job $a:" $T/daemon.log)
    sleep 0.5
    c=$(sub --lane c --class correctness --est 2 -- sleep 2)
    d=$(sub --lane d --class build --after $c --est 5 -- sleep 5)
    b=$(sub --lane b --est 1 -- sleep 1)
    idle
    sql "select id, lane, cls, round(started - submitted, 1), round(ended - submitted, 1) from jobs order by id" | sed 's/^/    /'
    late=$(sql "select round(b.started - c.ended, 1) from jobs b, jobs c where b.id = $b and c.id = $c")
    awk -v l="$late" 'BEGIN { exit !(l >= 0 && l <= 1.5) }' && ok "timing b started ${late} s after correctness c ended, not after build d" || bad "timing b started ${late} s after correctness c ended (build d takes 5 s)"
    gaps=$(( $(grep -c "build gap after job $a:" $T/daemon.log) - gaps_before ))
    [ "$gaps" = 0 ] && ok "no gap after job $a for the build behind a queued correctness job" || bad "a gap after job $a: $(grep "build gap after job $a:" $T/daemon.log | tail -1)"
    ;;
esac; done
[ -z "${daemon:-}" ] || kill "$daemon" 2>/dev/null
echo "result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
