#!/bin/sh
set -e

if [ "$#" -eq 0 ]; then
    "$(dirname -- "$0")/test-install-app.sh"
fi

developer_dir=${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}
developer_dir=${developer_dir%/}

if [ "$developer_dir" = /Library/Developer/CommandLineTools ] \
    && [ -e /Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework ]; then
    exec swift test "$@" \
        -Xswiftc -F \
        -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
        -Xlinker -rpath \
        -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
        -Xlinker -rpath \
        -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
fi

exec swift test "$@"
