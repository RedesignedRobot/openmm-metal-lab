#!/bin/sh
# Removes what xctrace leaves in the per-user temp dir: instruments*.ktrace (0.5-1.2 GB after a GPU trace) and
# xrgpu_aps_* (about 220 MB). Xcode-beta 27.2's xctrace leaves its ktrace behind on every exit, time limit, SIGINT or
# KILL alike, and ignores TMPDIR (it writes to `getconf DARWIN_USER_TEMP_DIR`), so a per-run TMPDIR catches nothing;
# tested 2026-09-28. A live recording owns its ktrace, so the sweep does nothing while any xctrace or Instruments runs.
# shader.sh calls this on exit; any script that runs xctrace itself should too. It clears every earlier run's
# leftovers as well, including those of a run that was itself killed before it could sweep.
T=$(getconf DARWIN_USER_TEMP_DIR)
if pgrep -x xctrace > /dev/null || pgrep -x Instruments > /dev/null; then
    echo "xctemp: xctrace or Instruments running, sweep skipped"
    exit 0
fi
left=$(find "$T" -maxdepth 1 \( -name 'instruments*.ktrace' -o -name 'xrgpu_aps_*' \))
[ -n "$left" ] || exit 0
echo "xctemp: removing $(echo "$left" | wc -l | tr -d ' ') xctrace leftovers, $(echo "$left" | tr '\n' '\0' | xargs -0 du -sck | tail -1 | cut -f1) KB"
echo "$left" | tr '\n' '\0' | xargs -0 rm -rf
