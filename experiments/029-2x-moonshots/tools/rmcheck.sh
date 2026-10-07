#!/bin/sh
# rmcheck.sh: removes each path read from stdin, one per line (blank and # lines skipped), only if
#   - no process has it, or anything under it, in its command line, open files or cwd (ps, lsof),
#   - no gpuq job that is queued, launching or running names it in its argv or cwd (gpuq refs),
#   - no old lease-legacy.sh ticket's process names it, and merge-queue.txt doesn't list it.
# Each path is matched as given, as its real path, and in both bench forms (/tmp/openmm-metal-bench and
# the real ~/code/metal/bench.noindex), with a name boundary: ultra-x doesn't match ultra-x-b. Paths come
# on stdin so rmcheck's own command line can never match them, and the command lines of its callers
# (the shell that piped the list, an agent's shell running `sh -c "printf ... | rmcheck.sh"`) don't count;
# their open files and cwd still do. If gpuqd doesn't answer, nothing is
# removed. Prints one line per path: "rm", "would rm" (DRY=1) or "SKIP" with the reason. Exits 1 when it
# refused any path, 2 on usage.
#   printf '%s\n' /tmp/openmm-metal-bench/ultra-old-lane | ultra-tools/rmcheck.sh
set -u
[ $# -eq 0 ] || { echo "usage: rmcheck.sh < paths (one per line; arguments are refused)" >&2; exit 2; }
B=/tmp/openmm-metal-bench
BREAL=$(cd $B && pwd -P)
HERE=$(cd "$(dirname "$0")" && pwd)
MERGE_QUEUE=$B/ultra-tools/merge-queue.txt
DRY=${DRY:-}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rmcheck.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# One snapshot of each source, taken before any removal. The ps snapshot leaves out rmcheck's ancestors.
ancestors=" "
p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    ancestors="$ancestors$p "
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
done
ps -axo pid=,command= | awk -v skip="$ancestors" 'index(skip, " " $1 " ") == 0' > "$tmp/ps"
lsof -Fpn 2>/dev/null | awk '/^p/ { pid = substr($0, 2) } /^n/ { print pid " " substr($0, 2) }' > "$tmp/lsof"
if ! /tmp/openmm-metal-bench/env/bin/python3 "$HERE/gpuq/gpuq" refs > "$tmp/gpuq" 2> "$tmp/gpuq.err"; then
    echo "SKIP all: gpuqd did not answer ($(tail -1 "$tmp/gpuq.err")); nothing removed"
    exit 1
fi
: > "$tmp/tickets"
for t in /tmp/openmm-lease-queue/* /tmp/openmm-lease/members/*; do
    [ -e "$t" ] || continue
    pid=${t##*-}; pid=${pid##*/}
    echo "$t $(ps -o command= -p "$pid" 2>/dev/null)" >> "$tmp/tickets"
done

# forms <path>: the path as given, its real path, and both bench forms, one per line, regex-escaped.
forms() {
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    {
        echo "$1"
        echo "$real"
        case "$real" in
        "$BREAL"/*) echo "$B/${real#"$BREAL"/}"; echo "/private$B/${real#"$BREAL"/}" ;;
        esac
    } | sed 's|//*|/|g; s|/$||' | sort -u | sed 's/[][\.*^$+?(){}|]/\\&/g'
}

refused=0
while IFS= read -r path; do
    case "$path" in ''|'#'*) continue ;; esac
    [ -e "$path" ] || { echo "SKIP $path: missing"; continue; }
    alts=$(forms "$path" | paste -sd '|' -)
    at="($alts)([^A-Za-z0-9._-]|\$)"
    procs=$(grep -E "$at" "$tmp/ps" | awk '{print $1}' | sort -u | tr '\n' ' ')
    open=$(grep -E "^[0-9]+ ($alts)(/|\$)" "$tmp/lsof" | awk '{print $1}' | sort -u | tr '\n' ' ')
    jobs=$(grep -E "$at" "$tmp/gpuq" | awk '{print $1 " " $2}' | paste -sd ',' -)
    tickets=$(grep -E "$at" "$tmp/tickets" | awk '{print $1}' | tr '\n' ' ')
    merge=$(forms "$path" | sed 's/\\//g' | grep -xF -f - "$MERGE_QUEUE" 2>/dev/null)
    if [ -n "$procs$open$jobs$tickets$merge" ]; then
        echo "SKIP $path: procs=[$procs] open=[$open] gpuq=[$jobs] tickets=[$tickets] merge=[$merge]"
        refused=1
        continue
    fi
    kb=$(du -sk "$path" | cut -f1)
    [ -n "$DRY" ] && { echo "would rm $path $kb KB"; continue; }
    rm -rf "$path" && echo "rm $path $kb KB"
done
exit $refused
