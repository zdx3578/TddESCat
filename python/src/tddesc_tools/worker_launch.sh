#!/bin/sh
output=$1
shift
/usr/bin/time -v -- "$@"
status=$?
printf '%s\n' "$status" > "$output/.worker-exit.tmp" || exit 23
mv -- "$output/.worker-exit.tmp" "$output/worker-exit.txt" || exit 23
# Keep the worker cgroup alive until the supervisor samples its final counters.
attempt=0
while [ ! -f "$output/.supervisor-sampled" ] && [ "$attempt" -lt 50 ]; do
    sleep 0.02
    attempt=$((attempt + 1))
done
exit "$status"
