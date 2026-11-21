#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
    echo 'Usage: build.sh PRIVATE_OUTPUT_DIRECTORY' >&2
    exit 2
fi
umask 077
sources=$(cd "$(dirname "$0")" && pwd)
export_app="$1/PhotoEarthLibrarySample.app"
import_app="$1/FixtureImport.app"
mkdir -p "$export_app/Contents/MacOS" "$import_app"
cp "$sources/ExporterInfo.plist" "$export_app/Contents/Info.plist"
cp "$sources/ImporterInfo.plist" "$import_app/Info.plist"
xcrun --sdk macosx swiftc -parse-as-library "$sources/Sample.swift" "$sources/Export.swift" -o "$export_app/Contents/MacOS/PhotoEarthLibrarySample"
xcrun --sdk appletvsimulator swiftc -parse-as-library -target "$(uname -m)-apple-tvos26.0-simulator" \
    -sdk "$(xcrun --sdk appletvsimulator --show-sdk-path)" "$sources/Sample.swift" "$sources/Import.swift" -o "$import_app/FixtureImport"
codesign -s - --force "$export_app"
codesign -s - --force "$import_app"
