#!/bin/zsh

# Claude Code sends structured status-line JSON on stdin. Keep only the
# account-level five-hour usage window needed by the notch app; never inspect
# Claude credentials, transcripts, project paths, or auth files.

INPUT_JSON="$(cat)"

extract_number() {
    local key_path="$1"
    local value

    value="$(
        printf '%s' "$INPUT_JSON" \
            | /usr/bin/plutil -extract "$key_path" raw -o - - 2>/dev/null
    )" || return 1

    [[ "$value" =~ '^-?[0-9]+([.][0-9]+)?$' ]] || return 1
    printf '%s' "$value"
}

USED_PERCENTAGE="$(
    extract_number rate_limits.five_hour.used_percentage
)" || exit 0
RESET_AT="$(extract_number rate_limits.five_hour.resets_at)" || exit 0
UPDATED_AT="$(date +%s)" || exit 0

REDUCED="$(
    printf \
        '{"version":2,"updatedAt":%s,"rateLimits":{"fiveHour":{"usedPercentage":%s,"resetsAt":%s}}}' \
        "$UPDATED_AT" \
        "$USED_PERCENTAGE" \
        "$RESET_AT"
)" || exit 0

# A fresh Claude session has no rate-limit fields until its first API response.
# Preserve the last valid snapshot instead of replacing it with empty data.
[ -n "$REDUCED" ] || exit 0

CACHE_DIR="$HOME/Library/Caches/com.bchen.CodexUsageMenuBar"
CACHE_FILE="$CACHE_DIR/claude-usage.json"

umask 077
mkdir -p "$CACHE_DIR" || exit 0
chmod 700 "$CACHE_DIR" 2>/dev/null

TEMP_FILE="$(mktemp "$CACHE_DIR/claude-usage.XXXXXX")" || exit 0
cleanup() {
    if [ -n "${TEMP_FILE:-}" ]; then
        rm -f "$TEMP_FILE"
    fi
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' "$REDUCED" > "$TEMP_FILE" || exit 0
chmod 600 "$TEMP_FILE" 2>/dev/null
mv -f "$TEMP_FILE" "$CACHE_FILE" || exit 0
TEMP_FILE=""
