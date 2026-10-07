#!/bin/sh
# Studio entrypoint. Includes dirty edits; one remote job holds the lock through sync/build/check.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../hosts.env"
export M2
exec /usr/bin/env python3 "$here/m2cand.py" "$@"
