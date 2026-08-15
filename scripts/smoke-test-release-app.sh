#!/bin/sh
set -eu

app_path=${1:-}
if [ -z "$app_path" ] || [ ! -d "$app_path" ]; then
    echo "Usage: smoke-test-release-app.sh /path/to/Quotakin.app" >&2
    exit 64
fi

executable="$app_path/Contents/MacOS/Quotakin"
if [ ! -x "$executable" ]; then
    echo "Missing packaged executable: $executable" >&2
    exit 1
fi

log_path=$(mktemp "${TMPDIR:-/tmp}/quotakin-smoke.XXXXXX")
waiter_pid=
app_pid=
cleanup() {
    if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
    fi
    if [ -n "$waiter_pid" ] && kill -0 "$waiter_pid" 2>/dev/null; then
        kill "$waiter_pid" 2>/dev/null || true
        wait "$waiter_pid" 2>/dev/null || true
    fi
    rm -f "$log_path"
}
trap cleanup EXIT HUP INT TERM

/usr/bin/open -n -W "$app_path" >"$log_path" 2>&1 &
waiter_pid=$!

# A missing embedded framework terminates immediately. Remaining alive through
# this bounded window proves the packaged executable passed dynamic loading and
# application startup.
attempt=0
while [ "$attempt" -lt 12 ]; do
    if ! kill -0 "$waiter_pid" 2>/dev/null; then
        wait "$waiter_pid" 2>/dev/null || status=$?
        echo "Packaged app exited during startup (status ${status:-unknown})." >&2
        sed -n '1,120p' "$log_path" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.25
done

app_pid=$(/usr/bin/pgrep -f "$executable" | /usr/bin/head -n 1 || true)
if [ -z "$app_pid" ]; then
    echo "Packaged app did not remain running after launch." >&2
    sed -n '1,120p' "$log_path" >&2
    exit 1
fi

echo "Packaged app remained running through startup."
