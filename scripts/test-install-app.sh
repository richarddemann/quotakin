#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
plan=$("$repo_root/scripts/install-app.sh" --dry-run --print-plan)
plist=$("$repo_root/scripts/install-app.sh" --dry-run --print-plist)
checked_in_icon="$repo_root/Sources/UsageBar/Resources/UsageBar.icns"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/usagebar-install-test.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

echo "$plan" | grep -F '"bundleName":"Quotakin.app"' >/dev/null
echo "$plan" | grep -F '"bundleIdentifier":"com.richarddemann.usagebar"' >/dev/null
echo "$plan" | grep -F '"executableName":"Quotakin"' >/dev/null
echo "$plan" | grep -F '"resourceBundleName":"Quotakin_UsageBar.bundle"' >/dev/null
echo "$plan" | grep -F '"iconFile":"Quotakin.icns"' >/dev/null
echo "$plan" | grep -F '"activationPolicy":"LSUIElement"' >/dev/null
echo "$plan" | grep -F '"relaunchesRunningApp":true' >/dev/null
echo "$plan" | grep -F "$HOME/Applications/Quotakin.app" >/dev/null
grep -F 'legacy_app_path="$install_root/UsageBar.app"' "$repo_root/scripts/install-app.sh" >/dev/null
grep -F 'legacy_installed_executable_path="$legacy_app_path/Contents/MacOS/UsageBar"' "$repo_root/scripts/install-app.sh" >/dev/null

printf '%s\n' "$plist" | /usr/bin/plutil -lint - >/dev/null
icon_name=$(printf '%s\n' "$plist" | /usr/bin/plutil -extract CFBundleIconFile raw -o - -)
minimum_system=$(printf '%s\n' "$plist" | /usr/bin/plutil -extract LSMinimumSystemVersion raw -o - -)
ui_element=$(printf '%s\n' "$plist" | /usr/bin/plutil -extract LSUIElement raw -o - -)
update_feed=$(printf '%s\n' "$plist" | /usr/bin/plutil -extract SUFeedURL raw -o - -)
automatic_update_checks=$(printf '%s\n' "$plist" | /usr/bin/plutil -extract SUEnableAutomaticChecks raw -o - -)
test "$icon_name" = Quotakin.icns
test "$minimum_system" = 26.0
test "$ui_element" = true
test "$update_feed" = "https://github.com/richarddemann/quotakin/releases/latest/download/appcast.xml"
test "$automatic_update_checks" = false

test -f "$checked_in_icon"
test -f "$repo_root/LICENSE"
test -f "$repo_root/THIRD_PARTY_NOTICES.md"
generated_icon="$temporary_root/UsageBar.icns"
SWIFT_MODULECACHE_PATH="$temporary_root/SwiftModuleCache" \
CLANG_MODULE_CACHE_PATH="$temporary_root/ClangModuleCache" \
    /usr/bin/swift "$repo_root/scripts/generate-app-icon.swift" \
        "$repo_root/docs/assets/quotakin-icon.png" "$generated_icon"
cmp "$checked_in_icon" "$generated_icon"

extracted_iconset="$temporary_root/UsageBar.iconset"
/usr/bin/iconutil --convert iconset --output "$extracted_iconset" "$checked_in_icon"
test -f "$extracted_iconset/icon_16x16.png"
test -f "$extracted_iconset/icon_512x512@2x.png"
