#!/bin/sh
set -eu

usage() {
    cat <<'USAGE'
Usage: create-release-assets.sh --app PATH --version VERSION --output-dir PATH [--identity IDENTITY]

Creates Quotakin-VERSION.zip and Quotakin-VERSION.dmg from a signed app.
USAGE
}

app_path=
version=
output_dir=
signing_identity=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            shift
            app_path=${1:-}
            ;;
        --version)
            shift
            version=${1:-}
            ;;
        --output-dir)
            shift
            output_dir=${1:-}
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

if [ -z "$app_path" ] || [ -z "$version" ] || [ -z "$output_dir" ]; then
    usage >&2
    exit 64
fi

if [ ! -d "$app_path" ] || [ "$(basename -- "$app_path")" != "Quotakin.app" ]; then
    echo "Expected a Quotakin.app bundle: $app_path" >&2
    exit 1
fi

case "$version" in
    *[!0-9A-Za-z.-]*|'')
        echo "Invalid version: $version" >&2
        exit 64
        ;;
esac

mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)
zip_path="$output_dir/Quotakin-$version.zip"
dmg_path="$output_dir/Quotakin-$version.dmg"

if [ -e "$zip_path" ] || [ -e "$dmg_path" ]; then
    echo "Release asset already exists in $output_dir" >&2
    exit 1
fi

stage_root=$(mktemp -d "${TMPDIR:-/tmp}/quotakin-assets.XXXXXX")
trap 'rm -rf "$stage_root"' EXIT HUP INT TERM
dmg_root="$stage_root/dmg"
mkdir -p "$dmg_root"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$stage_root/Quotakin.zip"
/usr/bin/ditto "$stage_root/Quotakin.zip" "$zip_path"

/usr/bin/ditto "$app_path" "$dmg_root/Quotakin.app"
/bin/ln -s /Applications "$dmg_root/Applications"
if /usr/sbin/diskutil image create from --help >/dev/null 2>&1; then
    /usr/sbin/diskutil image create from \
        --volumeName "Quotakin" \
        --format UDZO \
        "$dmg_root" \
        "$stage_root/Quotakin.dmg"
else
    /usr/bin/hdiutil create \
        -volname "Quotakin" \
        -srcfolder "$dmg_root" \
        -format UDZO \
        -ov \
        "$stage_root/Quotakin.dmg"
fi

if [ -n "$signing_identity" ]; then
    /usr/bin/codesign --force --timestamp --sign "$signing_identity" "$stage_root/Quotakin.dmg"
    /usr/bin/codesign --verify --verbose=2 "$stage_root/Quotakin.dmg"
fi

/usr/bin/hdiutil verify "$stage_root/Quotakin.dmg"
/usr/bin/ditto "$stage_root/Quotakin.dmg" "$dmg_path"

echo "Created $zip_path"
echo "Created $dmg_path"
