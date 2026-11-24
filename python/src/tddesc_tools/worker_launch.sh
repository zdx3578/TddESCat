#!/bin/sh
output=$1
shift
/usr/bin/time -v -- "$@"
status=$?
printf '%s\n' "$status" > "$output/.worker-exit.tmp" || exit 23
mv -- "$output/.worker-exit.tmp" "$output/worker-exit.txt" || exit 23
exit "$status"
