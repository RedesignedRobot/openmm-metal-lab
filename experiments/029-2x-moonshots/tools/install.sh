#!/bin/sh
# Install the lab's 029 tools without overwriting running scripts in place.
# Nothing is installed until the offline tests pass on an isolated gpuq instance (ultra-tools-test):
# gpuq/tests/accept.sh every time, plus each test whose "# covers:" line names a file that differs from
# its installed copy, or whose own file does. Tests that take a build.sh tree use INSTALL_TEST_TREE
# (default ultra-r2-fah-trunk, pinned). accept6.sh needs the GPU and stays manual. There is no skip.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bench=/tmp/openmm-metal-bench
dest=$bench/ultra-tools
tree=${INSTALL_TEST_TREE:-$bench/ultra-r2-fah-trunk}
scratch=$bench/ultra-tools-test
active=lease-legacy.sh
[ -e "$HOME/Library/LaunchAgents/com.openmm.gpuqd.plist" ] && active=gpuq/lease.sh

changed=""
for source in "$here"/* "$here"/gpuq/* "$here"/gpuq/tests/*; do
    [ -f "$source" ] || continue
    name=${source#"$here"/}
    cmp -s "$source" "$dest/$name" || changed="$changed $name"
done
cmp -s "$here/$active" "$dest/lease.sh" || changed="$changed $active"
tests="gpuq/tests/accept.sh"
for test in "$here"/gpuq/tests/*.sh "$here"/tests/*.sh; do
    name=${test#"$here"/}
    covered=$(sed -n '2s/^# covers: \([^(]*\).*/\1/p' "$test")
    [ -n "$covered" ] || continue
    for file in $name $covered; do
        case " $changed " in *" $file "*) tests="$tests $name"; break ;; esac
    done
done
echo "changed:${changed:- nothing}"
rm -rf "$scratch"
mkdir -p "$scratch"
failed=""
for name in $tests; do
    case $name in
    gpuq/tests/preflight.sh|gpuq/tests/outdirs.sh) arg=$tree ;;
    gpuq/tests/*) arg="" ;;
    *) arg=$scratch/$(basename "$name" .sh) ;;
    esac
    start=$(date +%s)
    if GPUQ_TEST_DIR=$scratch/gpuq sh "$here/$name" $arg > "$scratch/$(basename "$name").log" 2>&1; then
        echo "PASS $name ($(( $(date +%s) - start )) s)"
    else
        echo "FAIL $name ($(( $(date +%s) - start )) s):"
        grep -E '^ *FAIL' "$scratch/$(basename "$name").log" | head -5
        failed="$failed $name"
    fi
done
[ -z "$failed" ] || { echo "install.sh: nothing installed; failed:$failed (logs in $scratch)" >&2; exit 1; }
rm -rf "$scratch"

mkdir -p "$dest" "$bench/ultra-lead"
for source in "$here"/*; do
    [ -f "$source" ] || continue
    name=$(basename "$source")
    cp -p "$source" "$dest/$name.new"
    mv "$dest/$name.new" "$dest/$name"
done
mkdir -p "$dest/gpuq" "$dest/gpuq/tests"
for source in "$here"/gpuq/* "$here"/gpuq/tests/*; do
    [ -f "$source" ] || continue
    name=${source#"$here"/}
    cp -p "$source" "$dest/$name.new"
    mv "$dest/$name.new" "$dest/$name"
done
# lease.sh is the scheduler in use: gpuq's shim once gpuqd's launch agent is installed (the cutover),
# else the old FIFO lease. A reinstall never switches schedulers.
cp -p "$here/$active" "$dest/lease.sh.new"
mv "$dest/lease.sh.new" "$dest/lease.sh"
[ -e "$dest/merge-queue.txt" ] || : > "$dest/merge-queue.txt"
mkdir -p "$dest/tmpl"
"$bench/env/bin/python3" "$dest/shadertemplate.py" "$dest/tmpl/mst-shader.tracetemplate.new"
mv "$dest/tmpl/mst-shader.tracetemplate.new" "$dest/tmpl/mst-shader.tracetemplate"
# The launch agent is installed by hand (the plist's own comment), when the queue is empty, because a
# bootout stops gpuqd. install.sh only says when the running agent's copy differs from the lab's.
agent=$HOME/Library/LaunchAgents/com.openmm.gpuqd.plist
[ ! -e "$agent" ] || cmp -s "$here/gpuq/com.openmm.gpuqd.plist" "$agent" \
    || echo "install.sh: $agent differs from gpuq/com.openmm.gpuqd.plist; reinstall the launch agent when the queue is empty" >&2
