#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    printf 'usage: %s <pid> [duration-seconds=28800] [interval-seconds=5]\n' "$0" >&2
    exit 2
fi

collector_pid=$1
duration_seconds=${2:-28800}
interval_seconds=${3:-5}

case "$collector_pid:$duration_seconds:$interval_seconds" in
    *[!0-9:]*|::*|*::|:*)
        printf 'pid, duration, and interval must be positive integers\n' >&2
        exit 2
        ;;
esac

if [ "$collector_pid" -le 0 ] || [ "$duration_seconds" -le 0 ] || [ "$interval_seconds" -le 0 ]; then
    printf 'pid, duration, and interval must be positive integers\n' >&2
    exit 2
fi

if ! kill -0 "$collector_pid" 2>/dev/null; then
    printf 'process %s is not running\n' "$collector_pid" >&2
    exit 1
fi

started_at=$(date +%s)
finish_at=$((started_at + duration_seconds))
printf 'timestamp_utc,cpu_percent,rss_kb,elapsed\n'

while [ "$(date +%s)" -lt "$finish_at" ]; do
    if ! process_sample=$(ps -p "$collector_pid" -o %cpu= -o rss= -o etime=); then
        printf 'process %s ended before the sampling window completed\n' "$collector_pid" >&2
        exit 1
    fi
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    cpu=$(printf '%s\n' "$process_sample" | awk '{print $1}')
    rss=$(printf '%s\n' "$process_sample" | awk '{print $2}')
    elapsed=$(printf '%s\n' "$process_sample" | awk '{print $3}')
    printf '%s,%s,%s,%s\n' "$timestamp" "$cpu" "$rss" "$elapsed"
    sleep "$interval_seconds"
done
