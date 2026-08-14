#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Keep the legacy environment override and bundle identifier so existing local
# installs retain their preferences and notification authorization after the
# product rename.
install_root=${QUOTAKIN_INSTALL_ROOT:-${USAGEBAR_INSTALL_ROOT:-"$HOME/Applications"}}
app_name=Quotakin.app
bundle_id=com.richarddemann.usagebar
executable_name=Quotakin
resource_bundle_name=Quotakin_UsageBar.bundle
source_app_icon_name=UsageBar.icns
app_icon_name=Quotakin.icns
app_path="$install_root/$app_name"
legacy_app_path="$install_root/UsageBar.app"
open_after_install=1
dry_run=0
print_plan=0
print_plist=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            dry_run=1
            ;;
        --print-plan)
            print_plan=1
            ;;
        --print-plist)
            print_plist=1
            ;;
        --no-open)
            open_after_install=0
            ;;
        --install-root)
            shift
            install_root=${1:?missing install root}
            app_path="$install_root/$app_name"
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 64
            ;;
    esac
    shift
done

plan_json() {
    printf '{"bundleName":"%s","bundleIdentifier":"%s","executableName":"%s","resourceBundleName":"%s","iconFile":"%s","activationPolicy":"LSUIElement","relaunchesRunningApp":true,"installPath":"%s"}\n' \
        "$app_name" \
        "$bundle_id" \
        "$executable_name" \
        "$resource_bundle_name" \
        "$app_icon_name" \
        "$app_path"
}

write_info_plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$executable_name</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleIconFile</key>
    <string>$app_icon_name</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Quotakin</string>
    <key>CFBundleDisplayName</key>
    <string>Quotakin</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
}

if [ "$print_plan" -eq 1 ]; then
    plan_json
fi

if [ "$print_plist" -eq 1 ]; then
    write_info_plist
fi

if [ "$dry_run" -eq 1 ]; then
    exit 0
fi

cd "$repo_root" && swift build -c release
bin_path=$(cd "$repo_root" && swift build -c release --show-bin-path)

executable_path="$bin_path/$executable_name"
resource_bundle_path="$bin_path/$resource_bundle_name"
app_icon_path="$resource_bundle_path/$source_app_icon_name"
license_path="$repo_root/LICENSE"
third_party_notices_path="$repo_root/THIRD_PARTY_NOTICES.md"

if [ ! -x "$executable_path" ]; then
    echo "Missing built executable: $executable_path" >&2
    exit 1
fi

if [ ! -d "$resource_bundle_path" ]; then
    echo "Missing resource bundle: $resource_bundle_path" >&2
    exit 1
fi

if [ ! -f "$app_icon_path" ]; then
    echo "Missing built app icon: $app_icon_path" >&2
    exit 1
fi

if [ ! -f "$license_path" ] || [ ! -f "$third_party_notices_path" ]; then
    echo "Missing license files required for distribution." >&2
    exit 1
fi

# Replacing a bundle does not replace an already-running executable in memory.
# Stop only this installed bundle, leaving debug builds from other paths alone.
installed_executable_path="$app_path/Contents/MacOS/$executable_name"
legacy_installed_executable_path="$legacy_app_path/Contents/MacOS/UsageBar"
running_installed_pids() {
    /bin/ps -axo pid=,command= | while read -r pid command; do
        if [ "$command" = "$installed_executable_path" ] || [ "$command" = "$legacy_installed_executable_path" ]; then
            printf '%s\n' "$pid"
        fi
    done
}

installed_pids=$(running_installed_pids)
if [ -n "$installed_pids" ]; then
    for pid in $installed_pids; do
        /bin/kill -TERM "$pid" 2>/dev/null || true
    done
    attempts=0
    while [ -n "$(running_installed_pids)" ] && [ "$attempts" -lt 30 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
    if [ -n "$(running_installed_pids)" ]; then
        echo "Quotakin did not stop cleanly before install." >&2
        exit 1
    fi
fi

rm -rf "$app_path"
# The renamed bundle keeps the legacy identifier for settings continuity, so
# leaving both bundles installed would permit two processes to share one store.
if [ "$legacy_app_path" != "$app_path" ] && [ -d "$legacy_app_path" ]; then
    rm -rf "$legacy_app_path"
fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$executable_path" "$app_path/Contents/MacOS/$executable_name"
cp -R "$resource_bundle_path" "$app_path/Contents/Resources/$resource_bundle_name"
cp "$app_icon_path" "$app_path/Contents/Resources/$app_icon_name"
cp "$license_path" "$app_path/Contents/Resources/LICENSE.txt"
cp "$third_party_notices_path" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"

write_info_plist > "$app_path/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$app_path" >/dev/null
fi

/usr/bin/touch "$app_path"

if [ "$open_after_install" -eq 1 ]; then
    /usr/bin/open -a "$app_path"
fi

echo "Installed $app_path"
