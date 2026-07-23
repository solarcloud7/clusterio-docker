#!/bin/bash
# stream-logs.sh — shared helper: mirror Clusterio's on-disk JSON logs to container
# stdout so `docker logs` shows plugin logger output ("the #1 gotcha that wastes
# hours" — see docs/clusterio-engineering-notes.md #11).
#
# Usage:  source /scripts/stream-logs.sh
#         start_log_streamer /clusterio/logs/host host
#
# Gated by CLUSTERIO_LOG_TO_STDOUT (default true). Lines are prefixed
# `[cluster-log] ` so stdout stays greppable. Handles daily file rollover by
# re-resolving the filename when the UTC date changes; `tail -F` tolerates the
# file not existing yet (created on first log write).

start_log_streamer() {
    local dir="$1" prefix="$2"
    [ "${CLUSTERIO_LOG_TO_STDOUT:-true}" = "true" ] || return 0
    (
        while :; do
            local today file reader
            today=$(date -u +%F)
            file="$dir/${prefix}-${today}.log"
            tail -q -n 0 -F "$file" 2>/dev/null | while IFS= read -r line; do
                printf '[cluster-log] %s\n' "$line"
            done &
            reader=$!
            # Sleep until the UTC date rolls over, then re-resolve the filename.
            while [ "$(date -u +%F)" = "$today" ]; do sleep 60; done
            kill "$reader" 2>/dev/null || true
            pkill -f "tail -q -n 0 -F $file" 2>/dev/null || true
        done
    ) &
}
