#!/bin/zsh

# Claude Code sends structured status-line JSON on stdin. Keep only the
# account-level five-hour usage window needed by the notch app; never inspect
# Claude credentials, transcripts, project paths, or auth files.

JQ_PATH=""
for candidate in /opt/homebrew/bin/jq /usr/local/bin/jq; do
    if [ -x "$candidate" ]; then
        JQ_PATH="$candidate"
        break
    fi
done

if [ -z "$JQ_PATH" ]; then
    JQ_PATH="$(command -v jq 2>/dev/null)"
fi

if [ -z "$JQ_PATH" ]; then
    exit 0
fi

REDUCED="$($JQ_PATH -c '
    .rate_limits.five_hour as $five
    | if (
        (($five.used_percentage | type) != "number")
        or (($five.resets_at | type) != "number")
      ) then
        empty
      else
        {
            version: 2,
            updatedAt: now,
            rateLimits: {
                fiveHour: {
                    usedPercentage: $five.used_percentage,
                    resetsAt: $five.resets_at
                }
            }
        }
      end
' 2>/dev/null)" || exit 0

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
