#!/bin/sh
set -eu

usage() {
    cat <<'USAGE'
Usage: build-release-app.sh --version VERSION --build-number NUMBER --output PATH [--identity IDENTITY]

Builds a universal Quotakin.app for direct distribution. Use identity "-" only
for local packaging validation; public releases require a Developer ID
Application identity.
USAGE
}

version=
build_number=
output_path=
signing_identity=-

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            shift
            version=${1:-}
            ;;
        --build-number)
            shift
            build_number=${1:-}
            ;;
        --output)
            shift
            output_path=${1:-}
            ;;
        --identity)
            shift
            signing_identity=${1:-}
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
    shift
done

if [ -z "$version" ] || [ -z "$build_number" ] || [ -z "$output_path" ]; then
    usage >&2
    exit 64
fi

case "$version" in
    *[!0-9A-Za-z.-]*|'')
        echo "Invalid version: $version" >&2
        exit 64
        ;;
esac

case "$build_number" in
    *[!0-9]*|'')
        echo "Build number must contain digits only." >&2
        exit 64
        ;;
esac

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
module_cache_path="$repo_root/.build/release-module-cache"
mkdir -p "$module_cache_path"
export CLANG_MODULE_CACHE_PATH="$module_cache_path"
output_parent=$(dirname -- "$output_path")
mkdir -p "$output_parent"
output_parent=$(CDPATH= cd -- "$output_parent" && pwd)
output_path="$output_parent/$(basename -- "$output_path")"

if [ -e "$output_path" ]; then
    echo "Output already exists: $output_path" >&2
    exit 1
fi

stage_root=$(mktemp -d "${TMPDIR:-/tmp}/quotakin-app.XXXXXX")
trap 'rm -rf "$stage_root"' EXIT HUP INT TERM
app_path="$stage_root/Quotakin.app"

cd "$repo_root"
swift build -c release --disable-sandbox --arch arm64 --arch x86_64
bin_path=$(swift build -c release --disable-sandbox --arch arm64 --arch x86_64 --show-bin-path)

executable_path="$bin_path/Quotakin"
resource_bundle_path="$bin_path/Quotakin_UsageBar.bundle"
sparkle_framework_path="$bin_path/Sparkle.framework"
app_icon_path="$resource_bundle_path/UsageBar.icns"
if [ ! -f "$app_icon_path" ]; then
    app_icon_path="$resource_bundle_path/Contents/Resources/UsageBar.icns"
fi

if [ ! -x "$executable_path" ]; then
    echo "Missing built executable: $executable_path" >&2
    exit 1
fi

if [ ! -d "$resource_bundle_path" ] || [ ! -f "$app_icon_path" ] || [ ! -d "$sparkle_framework_path" ]; then
    echo "Missing release resources in $bin_path" >&2
    exit 1
fi

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Frameworks"
/usr/bin/ditto "$executable_path" "$app_path/Contents/MacOS/Quotakin"
/usr/bin/ditto "$resource_bundle_path" "$app_path/Contents/Resources/Quotakin_UsageBar.bundle"
/usr/bin/ditto "$sparkle_framework_path" "$app_path/Contents/Frameworks/Sparkle.framework"
/usr/bin/ditto "$app_icon_path" "$app_path/Contents/Resources/Quotakin.icns"
/usr/bin/ditto "$repo_root/LICENSE" "$app_path/Contents/Resources/LICENSE.txt"
/usr/bin/ditto "$repo_root/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"

cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Quotakin</string>
    <key>CFBundleIdentifier</key>
    <string>com.richarddemann.usagebar</string>
    <key>CFBundleIconFile</key>
    <string>Quotakin.icns</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Quotakin</string>
    <key>CFBundleDisplayName</key>
    <string>Quotakin</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$build_number</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://github.com/richarddemann/quotakin/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>WHeTB+yjYiUnLi3EhVsgEgCfa3MyllBs3gQJHFTxzJI=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
PLIST

if [ "$signing_identity" = "-" ]; then
    /usr/bin/codesign --force --sign - "$app_path"
else
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$signing_identity" \
        "$app_path"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
/usr/bin/lipo "$app_path/Contents/MacOS/Quotakin" -verify_arch arm64 x86_64

/usr/bin/ditto "$app_path" "$output_path"
echo "Built $output_path"
