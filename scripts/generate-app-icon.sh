#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_script="$repo_root/scripts/generate-app-icon.swift"
source_png="$repo_root/docs/assets/quotakin-icon.png"
output_icns="$repo_root/Sources/UsageBar/Resources/UsageBar.icns"

if [ ! -f "$source_script" ] || [ ! -f "$source_png" ]; then
    echo "Missing app icon source." >&2
    exit 1
fi

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/usagebar-app-icon.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

SWIFT_MODULECACHE_PATH="$temporary_root/SwiftModuleCache" \
CLANG_MODULE_CACHE_PATH="$temporary_root/ClangModuleCache" \
    /usr/bin/swift "$source_script" "$source_png" "$output_icns"
echo "Generated $output_icns"
