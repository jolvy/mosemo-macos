#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf 'usage: %s <process-samples.csv>\n' "$0" >&2
    exit 2
fi

awk -F, '
    NR == 1 { next }
    NF >= 3 {
        samples += 1
        cpu_sum += $2
        if ($3 > max_rss) max_rss = $3
    }
    END {
        if (samples == 0) {
            print "no samples" > "/dev/stderr"
            exit 1
        }
        printf "samples=%d\n", samples
        printf "average_cpu_percent=%.3f\n", cpu_sum / samples
        printf "maximum_rss_mb=%.3f\n", max_rss / 1024
    }
' "$1"
