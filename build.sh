#!/bin/zsh
set -eu
cd "$(dirname "$0")"
swift build -c release
DEST="${1:-../Stillroom Studio.app}"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp .build/release/Stillroom "$DEST/Contents/MacOS/Stillroom"
cp Info.plist "$DEST/Contents/Info.plist"
if [[ -d Resources/Demo/Media ]]; then
    ditto Resources "$DEST/Contents/Resources"
elif [[ -d "../Stillroom Studio.app/Contents/Resources" ]]; then
    RESOURCES="${PWD:h}/Stillroom Studio.app/Contents/Resources"
    if [[ "${RESOURCES:A}" != "${DEST:A}/Contents/Resources" ]]; then
        ditto "$RESOURCES" "$DEST/Contents/Resources"
    fi
fi
codesign --force --deep --sign - "$DEST"
echo "Built $DEST"
