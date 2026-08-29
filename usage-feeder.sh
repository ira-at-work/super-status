#!/bin/bash
# super-status usage feeder
#
# Detached background job that periodically asks Claude Code for the account's
# 5h / weekly rate-limit usage via the zero-token `get_usage` control request and
# writes it to the JSON snapshot the statusline reads (`external_usage_path`).
#
# Why this exists: Claude Code only puts `rate_limits` on the statusline's stdin
# after a live API call, so an idle or freshly-cleared session shows no 5h/Nd
# bars. statusline.sh already restores the last-seen values from disk, but only
# this session's last values — it can't reflect usage another session or machine
# consumed while this one sat idle. This feeder closes that gap by refreshing the
# snapshot out-of-band.
#
# Hard constraint discovered empirically: the get_usage backend THROTTLES rapid
# calls — the first call returns real data, subsequent rapid calls return null
# `rate_limits`. So this runs on a conservative base interval and backs off
# exponentially whenever a call comes back empty, and it NEVER overwrites a good
# snapshot with a null response. A 10s cadence is deliberately not the default:
# it would keep the endpoint permanently throttled and starve the feeder of data.
#
# Usage:
#   usage-feeder.sh run        # loop forever (what launchd runs)
#   usage-feeder.sh once       # single fetch + write, then exit
#   usage-feeder.sh status     # report snapshot freshness + whether a loop runs
#   usage-feeder.sh stop       # signal a running loop to exit
#
# Env overrides (all optional):
#   SS_FEEDER_INTERVAL      base seconds between successful fetches   (default 300)
#   SS_FEEDER_MAX_INTERVAL  backoff ceiling in seconds                (default 1800)
#   SS_FEEDER_HOLD          seconds to hold the get_usage call open   (default 12)
#   SS_FEEDER_SNAPSHOT      snapshot output path                      (default ~/.claude/super-status/usage-snapshot.json)
#   SS_FEEDER_LOG           log file path                             (default ~/.claude/super-status/usage-feeder.log)

set -u

BASE_INTERVAL="${SS_FEEDER_INTERVAL:-300}"
MAX_INTERVAL="${SS_FEEDER_MAX_INTERVAL:-1800}"
HOLD="${SS_FEEDER_HOLD:-12}"
SNAPSHOT="${SS_FEEDER_SNAPSHOT:-$HOME/.claude/super-status/usage-snapshot.json}"
LOG="${SS_FEEDER_LOG:-$HOME/.claude/super-status/usage-feeder.log}"
STATE_DIR="$HOME/.claude/super-status/.feeder"
LOCK_DIR="$STATE_DIR/run.lock"
STOP_FLAG="$STATE_DIR/stop"

mkdir -p "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null

LOG_MAX_BYTES=1048576

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
        tail -c 524288 "$LOG" > "$LOG.trim" 2>/dev/null && mv "$LOG.trim" "$LOG" 2>/dev/null
    fi
    printf '%s [%s] %s\n' "$ts" "$$" "$1" >> "$LOG" 2>/dev/null
}

require() {
    local missing=0 tool
    for tool in claude jq; do
        command -v "$tool" >/dev/null 2>&1 || { echo "usage-feeder: required tool not found: $tool" >&2; missing=1; }
    done
    [ "$missing" -eq 0 ] || exit 1
}

# Ask Claude Code for usage and print the reader-shaped snapshot JSON on stdout.
# Prints nothing and returns non-zero when the response carries no usable data
# (throttled / null / not a subscription), so callers can skip the write.
fetch_snapshot() {
    local raw resp util
    # Hold stdin open ($HOLD s) so the async usage fetch resolves before Claude
    # Code tears the --print session down; the downstream reader breaks on the
    # first control_response, which closes the pipe and lets the pipeline exit
    # early once data has arrived.
    raw=$(
        { printf '%s\n' '{"type":"control_request","request_id":"ss-feeder","request":{"subtype":"get_usage"}}'; sleep "$HOLD"; } \
        | claude --input-format stream-json --output-format stream-json --print --verbose 2>/dev/null \
        | while IFS= read -r line; do
            if [ "${line#*\"control_response\"}" != "$line" ]; then
                printf '%s\n' "$line"; break
            fi
          done
    )

    [ -n "$raw" ] || { log "fetch: no control_response received"; return 1; }

    util=$(printf '%s' "$raw" | jq -r '(.response.response.rate_limits // .response.rate_limits).five_hour.utilization // empty' 2>/dev/null)
    if [ -z "$util" ]; then
        log "fetch: rate_limits empty (throttled or unavailable)"
        return 1
    fi

    resp=$(printf '%s' "$raw" | jq -c \
        --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
        (.response.response.rate_limits // .response.rate_limits) as $r
        | {
            updated_at: $now,
            rate_limits: {
              five_hour: { used_percentage: $r.five_hour.utilization, resets_at: $r.five_hour.resets_at },
              seven_day: { used_percentage: $r.seven_day.utilization, resets_at: $r.seven_day.resets_at }
            }
          }' 2>/dev/null)

    if [ -z "$resp" ] || [ "$resp" = "null" ]; then
        log "fetch: response present but transform failed"
        return 1
    fi

    printf '%s\n' "$resp"
}

write_snapshot() {
    local json="$1" tmp
    tmp="$SNAPSHOT.tmp.$$"
    mkdir -p "$(dirname "$SNAPSHOT")" 2>/dev/null
    if printf '%s\n' "$json" > "$tmp" 2>/dev/null; then
        chmod 600 "$tmp" 2>/dev/null
        mv "$tmp" "$SNAPSHOT" 2>/dev/null && return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
}

do_once() {
    local snap
    if snap=$(fetch_snapshot); then
        if write_snapshot "$snap"; then
            log "wrote snapshot: $(printf '%s' "$snap" | jq -c '.rate_limits | {five: .five_hour.used_percentage, seven: .seven_day.used_percentage}')"
            return 0
        fi
        log "write failed: $SNAPSHOT"
        return 1
    fi
    return 1
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null
        return 0
    fi
    local other
    other=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        echo "usage-feeder: already running (pid $other)" >&2
        return 1
    fi
    # Stale lock from a crashed run — reclaim it.
    rm -rf "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null && printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null
}

release_lock() { rm -rf "$LOCK_DIR" 2>/dev/null; }

run_loop() {
    require
    acquire_lock || exit 1
    rm -f "$STOP_FLAG" 2>/dev/null
    trap 'log "loop stopping (signal)"; release_lock; exit 0' INT TERM
    log "loop start: base=${BASE_INTERVAL}s max=${MAX_INTERVAL}s hold=${HOLD}s snapshot=$SNAPSHOT"

    local interval="$BASE_INTERVAL"
    while :; do
        [ -f "$STOP_FLAG" ] && { log "loop stopping (stop flag)"; rm -f "$STOP_FLAG" 2>/dev/null; break; }

        if do_once; then
            interval="$BASE_INTERVAL"
        else
            interval=$(( interval * 2 ))
            [ "$interval" -gt "$MAX_INTERVAL" ] && interval="$MAX_INTERVAL"
            log "backing off to ${interval}s"
        fi

        # Sleep in short slices so a stop flag / signal is honored promptly.
        local waited=0
        while [ "$waited" -lt "$interval" ]; do
            [ -f "$STOP_FLAG" ] && break
            sleep 2
            waited=$(( waited + 2 ))
        done
    done
    release_lock
}

cmd_status() {
    if [ -d "$LOCK_DIR" ]; then
        local pid; pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "loop: running (pid $pid)"
        else
            echo "loop: stale lock (no live process)"
        fi
    else
        echo "loop: not running"
    fi
    if [ -f "$SNAPSHOT" ]; then
        local age
        age=$(( $(date +%s) - $(stat -f %m "$SNAPSHOT" 2>/dev/null || stat -c %Y "$SNAPSHOT" 2>/dev/null || echo 0) ))
        echo "snapshot: $SNAPSHOT (age ${age}s)"
        jq -c '{five: .rate_limits.five_hour.used_percentage, seven: .rate_limits.seven_day.used_percentage, updated_at: .updated_at}' "$SNAPSHOT" 2>/dev/null
    else
        echo "snapshot: none yet ($SNAPSHOT)"
    fi
}

case "${1:-run}" in
    run)    run_loop ;;
    once)   require; do_once && echo "ok" || { echo "no data (throttled/unavailable) — snapshot left unchanged" >&2; exit 1; } ;;
    status) cmd_status ;;
    stop)   touch "$STOP_FLAG" 2>/dev/null; echo "stop signalled" ;;
    *)      echo "usage: $0 {run|once|status|stop}" >&2; exit 2 ;;
esac
