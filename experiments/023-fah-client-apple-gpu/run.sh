#!/bin/zsh
# Usage: run.sh <fah-client binary> <run dir> <seconds> [GPU ID to enable]
#
# Runs a client from an empty directory with no account.  The assignment and
# API servers point at 127.0.0.1, where nothing listens on 443, so no request
# can reach FAH.  gpus.json is copied in fresh, so the client does not fetch it.
bin=$1 dir=$2 secs=$3 gpu=$4
lab=$HOME/lab/fah-client
py=$lab/venv/bin/python
probe=${0:A:h}/ws_probe.py

rm -rf $dir && mkdir -p $dir && cd $dir
cp ${GPUS_JSON:-$lab/gpus-cache/gpus.json} gpus.json

$bin --verbosity 5 --log log.txt \
  --assignment-servers 127.0.0.1 --api-server https://127.0.0.1 \
  > stdout.txt 2>&1 &
pid=$!
trap 'kill -INT $pid 2>/dev/null' EXIT
sleep 3

$py $probe state > state-before.json
if [[ -n $gpu ]]; then
  $py $probe enable $gpu
  sleep $secs
  $py $probe state > state-after.json
else
  sleep $secs
fi

kill -INT $pid
sleep 3
kill -0 $pid 2>/dev/null && kill $pid
sed -i '' $'s/\x1b\\[[0-9;]*m//g' log.txt
exit 0
