#!/bin/sh
set -eu

# Gate script for Experiment 013.
# Checks that results.md exists and contains a row for every Metal test
# listed by ctest -N. Does not rebuild or rerun tests. Leaves tracked files unchanged.

dir="$(cd "$(dirname "$0")" && pwd)"
results_file="$dir/results.md"
build_dir="${BUILD_DIR:-/Users/mas/code/wt/openmm-norpg/build}"

if [ ! -f "$results_file" ]; then
    echo "Gate error: results.md not found at $results_file" >&2
    exit 1
fi

if [ ! -d "$build_dir" ]; then
    echo "Gate error: build directory not found at $build_dir" >&2
    exit 1
fi

if command -v ctest >/dev/null 2>&1; then
    ctest_cmd="ctest"
elif [ -x /opt/homebrew/bin/ctest ]; then
    ctest_cmd="/opt/homebrew/bin/ctest"
elif [ -x /opt/homebrew/opt/cmake/bin/ctest ]; then
    ctest_cmd="/opt/homebrew/opt/cmake/bin/ctest"
elif command -v uv >/dev/null 2>&1; then
    ctest_cmd="uv run --with cmake ctest"
else
    echo "Gate error: no ctest executable found" >&2
    exit 1
fi

metal_tests=$($ctest_cmd --test-dir "$build_dir" -N -R Metal | sed -n 's/^[[:space:]]*Test[[:space:]]*#[0-9]*:[[:space:]]*//p')

if [ -z "$metal_tests" ]; then
    echo "Gate error: ctest -N found no Metal tests in $build_dir" >&2
    exit 1
fi

missing_count=0
for test_name in $metal_tests; do
    if ! grep -q "$test_name" "$results_file"; then
        echo "Gate error: test '$test_name' has no row in $results_file" >&2
        missing_count=$((missing_count + 1))
    fi
done

if [ "$missing_count" -ne 0 ]; then
    exit 1
fi

echo "Gate passed: all Metal tests listed by ctest -N are present in results.md"
exit 0
