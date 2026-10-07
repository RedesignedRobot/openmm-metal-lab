#!/bin/sh
# Copy the working tree, including edits and untracked non-ignored files.
set -eu
exec /usr/bin/env python3 "$(dirname "$0")/sync.py" "$@"
