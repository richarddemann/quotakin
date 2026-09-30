#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:-run}
case "$mode" in
    run|--verify|--debug|--logs|--telemetry) ;;
    *) echo "Usage: $0 [--verify|--debug|--logs|--telemetry]" >&2; exit 64 ;;
esac
install_root=${QUOTAKIN_INSTALL_ROOT:-"$HOME/Applications"}
if [ -z "${QUOTAKIN_INSTALL_ROOT:-}" ] && [ -d /Applications/Quotakin.app ]; then
    install_root=/Applications
fi
# Reuse the installer for resources, Sparkle, signing, and stopping this bundle.
"$repo_root/scripts/install-app.sh" --install-root "$install_root" --no-open
app_path="$install_root/Quotakin.app"
if [ "$mode" = --debug ]; then
    exec lldb -- "$app_path/Contents/MacOS/Quotakin"
fi
/usr/bin/open -n "$app_path"
case "$mode" in
    --verify) sleep 1; /usr/bin/pgrep -x Quotakin >/dev/null ;;
    --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "Quotakin"' ;;
    --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.richarddemann.usagebar"' ;;
esac
