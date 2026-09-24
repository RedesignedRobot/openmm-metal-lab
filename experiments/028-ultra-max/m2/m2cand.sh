#!/bin/sh
# Runs on the laptop: the whole M2 check of one or more candidates, from a worktree and commits.
# 1. m2sync.sh puts the first commit into /Users/amir/lab/ultra-m2/cand/src, the second into cand2,
#    and so on (rolling trees: only changed files are rewritten, so ninja rebuilds only those).
# 2. On the M2, detached at nice 0: m2build.sh for each tree (nice 10), then one m2check.sh session
#    with every candidate against base, so base runs once per (round, test, precision).
# 3. Waits in the foreground (30 s polls) for "CHECK DONE" or a failure, then prints the log.
# The M2 log is /Users/amir/lab/ultra-m2/checks/run-<UTC time>.out. Options go to m2check.sh, for
# example "-r 1 -s 5 -t gbsa,pme" for a smoke run.
# usage: m2cand.sh [-r rounds] [-s seconds] [-t tests] <worktree> <commit>...
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../hosts.env"
ROOT=/Users/amir/lab/ultra-m2
opts=""
while getopts r:s:t: flag; do
    case $flag in
    r|s|t) opts="$opts -$flag $OPTARG" ;;
    *) echo "usage: m2cand.sh [-r rounds] [-s seconds] [-t tests] <worktree> <commit>..." >&2; exit 2 ;;
    esac
done
shift $((OPTIND-1))
[ $# -ge 2 ] || { echo "usage: m2cand.sh [-r rounds] [-s seconds] [-t tests] <worktree> <commit>..." >&2; exit 2; }
worktree="$1"
shift
trees=""
builds=""
i=1
for spec in "$@"; do
    commit="$(git -C "$worktree" rev-parse --verify "$spec^{commit}")"
    tree="$ROOT/cand"
    [ $i -gt 1 ] && tree="$ROOT/cand$i"
    echo "$(date -u +%H:%M:%SZ) sync $commit into $tree"
    "$here/m2sync.sh" "$worktree" "$commit" "$tree"
    trees="$trees $tree"
    builds="$builds$ROOT/tools/m2build.sh $tree && "
    i=$((i+1))
done
log="$ROOT/checks/run-$(date -u +%Y%m%dT%H%M%SZ).out"
echo "$(date -u +%H:%M:%SZ) build and check on the M2, log $log"
timeout 60 ssh -o ConnectTimeout=15 "$M2" "mkdir -p $ROOT/checks && /bin/sh -c 'nohup /bin/sh -c \"$builds$ROOT/tools/m2check.sh$opts$trees\" > $log 2>&1 < /dev/null &'"
last=""
until [ -n "$(timeout 60 ssh -o ConnectTimeout=15 "$M2" "grep -E '^(CHECK DONE|CHECK FAILED|BUILD FAILED)' $log" 2>/dev/null || true)" ]; do
    now="$(timeout 60 ssh -o ConnectTimeout=15 "$M2" "tail -1 $log" 2>/dev/null || true)"
    [ "$now" != "$last" ] && echo "$(date -u +%H:%M:%SZ) $now"
    last="$now"
    sleep 30
done
timeout 60 ssh -o ConnectTimeout=15 "$M2" "cat $log"
