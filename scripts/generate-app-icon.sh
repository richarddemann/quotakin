#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_script="$repo_root/scripts/generate-app-icon.swift"
output_icns="$repo_root/Sources/UsageBar/Resources/UsageBar.icns"

if [ ! -f "$source_script" ]; then
    echo "Missing app icon source: $source_script" >&2
    exit 1
fi

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/usagebar-app-icon.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

SWIFT_MODULECACHE_PATH="$temporary_root/SwiftModuleCache" \
CLANG_MODULE_CACHE_PATH="$temporary_root/ClangModuleCache" \
    /usr/bin/swift "$source_script" "$output_icns"
echo "Generated $output_icns"
