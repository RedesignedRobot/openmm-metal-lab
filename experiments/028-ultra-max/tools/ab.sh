#!/bin/sh
# Runs on the M3 Ultra at nice 0: interleaved benchmark.py rounds over any number of configurations.
# A configuration is label=python:platform:precision[:VAR=value,...], with an absolute python path
# (a venv made by build.sh) and optional environment settings for that run only. Every
# (round, test, configuration) runs in a fresh process. Within a test the configurations run back to
# back, in reversed order every other round. The whole screen is one lease.sh timing hold: ab.sh
# re-execs itself through lease.sh once, so it queues one ticket, and the per-(round, test) lease.sh
# calls inside run at once. Inside another hold (window.sh, or your own lease.sh) it runs at once.
# The lane comes from the outdir (/tmp/openmm-metal-bench/ultra-<lane>/...) or AB_LANE.
# It prints an estimate first: every run is <seconds> plus the setup measured for its test on the M3
# Ultra (twice <seconds> on the CPU platform, whose step count overshoots). Outside a window it
# refuses a screen over 18 minutes, under lease.sh's 20 minute cap; split it by test. A run that
# starts with a build running, or overlaps one that starts during it, is marked BUILD RUNNING in
# loads.txt. --rerun-builds (window.sh) reruns every (round, test) with a marked run once at the end,
# all configurations in that round's order; the replaced results move to <outdir>/replaced.
# benchmark.py times with the host clock: datetime.now() around step(), plus a getState() sync.
# The load averages, the Hyperscale VM's CPU and the top 5 CPU processes before every run go to
# <outdir>/loads.txt; each configuration's openmm, revision and build go to <outdir>/configs.txt.
# <outdir> must be new or empty. <tests> is a comma list, or "all" for the 9 benchmark.py tests. A run that writes no result
# is logged as NO RESULT; a run over <seconds>+900 s is killed.
#   /bin/sh -c 'nohup /tmp/openmm-metal-bench/ultra-tools/ab.sh /tmp/openmm-metal-bench/ultra-<lane>/ab1 2 15 gbsa,rf,pme base=/tmp/openmm-metal-bench/ultra-base/venv/bin/python:Metal:single mine=/tmp/openmm-metal-bench/ultra-<lane>/venv/bin/python:Metal:single > /tmp/openmm-metal-bench/ultra-<lane>/ab1.out 2>&1 < /dev/null &'
# usage: ab.sh [--rerun-builds] <outdir> <rounds> <seconds> <tests|all> <configuration>...
set -eu
TOOLS=/tmp/openmm-metal-bench/ultra-tools
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
ALL=gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme,amber20-dhfr,amber20-cellulose,amber20-stmv
SCREEN_MAX_SECONDS=1080
unset PYTHONPATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0: launch through /bin/sh -c 'nohup ...'" >&2; exit 2; }
rerun_builds=0
[ "${1:-}" = --rerun-builds ] && { rerun_builds=1; shift; }
[ $# -ge 5 ] || { echo "usage: ab.sh [--rerun-builds] <outdir> <rounds> <seconds> <tests|all> <configuration>..." >&2; exit 2; }
tests_arg="$4"
case "$1" in
/*) out="${1%/}" ;;
*) echo "the outdir must be an absolute path" >&2; exit 2 ;;
esac
rounds="$2"
seconds="$3"
tests="$4"
[ "$tests" = all ] && tests=$ALL
tests="$(echo "$tests" | tr , ' ')"
shift 4
lane="$(echo "$out" | sed -n 's|^/tmp/openmm-metal-bench/\(ultra-[^/]*\)/.*|\1|p')"
lane="${lane:-${AB_LANE:-}}"
[ -n "$lane" ] || { echo "no lane: put the outdir under /tmp/openmm-metal-bench/ultra-<lane>/ or set AB_LANE" >&2; exit 2; }
mkdir -p "$out"
[ -z "$(ls -A "$out")" ] || { echo "$out is not empty; use a new outdir per run" >&2; exit 2; }

# Seconds of setup per run beyond the timed <seconds>, from 028's runs on the M3 Ultra: imports,
# system build, Context, calibration steps and exit (the minimizer too for amber20).
setup_seconds() {
    case "$1:$2" in
    amber20-cellulose:mixed) echo 47 ;;
    amber20-cellulose:*) echo 12 ;;
    amber20-stmv:*) echo 60 ;;
    amoebapme:*) echo 20 ;;
    amoebagk:*) echo 15 ;;
    apoa1*:*) echo 6 ;;
    *) echo 4 ;;
    esac
}

labels=""
config_lines=""
estimate=0
for config in "$@"; do
    label="${config%%=*}"
    IFS=: read -r python platform precision settings <<SPEC
${config#*=}
SPEC
    case "$label" in
    ""|*[!A-Za-z0-9_.-]*) echo "bad label '$label' in $config: use letters, digits, '.', '_' and '-'" >&2; exit 2 ;;
    esac
    case " $labels " in *" $label "*) echo "label $label is used twice" >&2; exit 2 ;; esac
    labels="$labels $label"
    case "$python" in /*) ;; *) echo "python must be an absolute path in $config" >&2; exit 2 ;; esac
    [ -x "$python" ] || { echo "$python is not executable" >&2; exit 2; }
    case "$platform:$precision" in Metal:single|Metal:mixed|OpenCL:single|CPU:single|CPU:mixed) ;;
    *) echo "platform:precision $platform:$precision is not one of Metal:single, Metal:mixed, OpenCL:single, CPU:*" >&2; exit 2 ;;
    esac
    dir="${python%/venv/bin/python}"
    built="not a build.sh tree"
    if [ "$dir" != "$python" ] && [ -d "$dir/build" ]; then
        [ -f "$dir/BUILT" ] || { echo "$dir/BUILT is missing: a build.sh is running there, or the last one failed" >&2; exit 2; }
        [ "$(sed -n 's/^src //p' "$dir/BUILT")" = "$("$TOOLS/srchash.sh" "$dir")" ] \
            || { echo "$dir/src changed after build.sh; rebuild before timing $label" >&2; exit 2; }
        built="$(tr '\n' ' ' < "$dir/BUILT")"
    fi
    info="$(cd / && "$python" -c "import openmm; print(openmm.__file__, openmm.version.git_revision)")" \
        || { echo "$python can't import openmm" >&2; exit 2; }
    config_lines="$config_lines$label $platform $precision settings=${settings:-none} $info $built
"
    for test in $tests; do
        run=$((seconds + $(setup_seconds "$test" "$precision")))
        [ "$platform" = CPU ] && run=$((run + seconds))
        estimate=$((estimate + rounds * run))
    done
done
if [ -z "${AB_HELD:-}" ]; then
    echo "estimate: $rounds rounds, $(echo $tests | wc -w | tr -d ' ') tests, $# configurations, about $((estimate / 60)) min $((estimate % 60)) s"
    [ -n "${OPENMM_WINDOW:-}" ] || [ $estimate -le $SCREEN_MAX_SECONDS ] \
        || { echo "the estimate is over $((SCREEN_MAX_SECONDS / 60)) minutes: split the screen by test into several ab.sh calls" >&2; exit 2; }
    rerun_flag=""
    [ $rerun_builds = 1 ] && rerun_flag=--rerun-builds
    export AB_HELD=1
    exec "$TOOLS/lease.sh" "$lane" "ab.sh $out, about $(((estimate + 59) / 60)) min" "$0" $rerun_flag "$out" "$rounds" "$seconds" "$tests_arg" "$@"
fi
printf '%s' "$config_lines" > "$out/configs.txt"
cat "$out/configs.txt"

reversed="$(echo "$@" | tr ' ' '\n' | tail -r | tr '\n' ' ')"
cd "$BENCH"
r=1
while [ "$r" -le "$rounds" ]; do
    order="$*"
    [ $((r % 2)) -eq 0 ] && order="$reversed"
    for test in $tests; do
        export AB_OUT="$out" AB_ROUND="$r" AB_TEST="$test" AB_SECONDS="$seconds"
        "$TOOLS/lease.sh" "$lane" "ab.sh $out round $r $test" "$TOOLS/ab-test.sh" $order \
            || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) round $r $test ended with exit $?" | tee -a "$out/loads.txt"
    done
    r=$((r+1))
done
if [ $rerun_builds = 1 ]; then
    for run in $(sed -n 's/^[^ ]* round \([0-9]*\) \([^ ]*\) .*BUILD RUNNING.*/\1:\2/p' "$out/loads.txt" | sort -u); do
        r="${run%%:*}"
        test="${run#*:}"
        order="$*"
        [ $((r % 2)) -eq 0 ] && order="$reversed"
        mkdir -p "$out/replaced"
        for label in $labels; do
            mv "$out/$label-$test-round$r.json" "$out/replaced/" 2>/dev/null || true
        done
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) rerun round $r $test: a build overlapped it" | tee -a "$out/loads.txt"
        export AB_OUT="$out" AB_ROUND="$r" AB_TEST="$test" AB_SECONDS="$seconds"
        "$TOOLS/lease.sh" "$lane" "ab.sh $out rerun round $r $test" "$TOOLS/ab-test.sh" $order \
            || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) rerun round $r $test ended with exit $?" | tee -a "$out/loads.txt"
    done
fi
echo "done $out"
