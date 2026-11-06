#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
name="${1:-Bubblegum}"
if [[ ! "$name" =~ ^[A-Z][A-Za-z0-9]{1,39}$ ]] || [[ ! -d "$root/Experiments/$name/$name.xcodeproj" ]]; then
    printf 'Unknown experiment: %s\n' "$name" >&2
    exit 1
fi
xcodebuild -quiet -project "$root/Experiments/$name/$name.xcodeproj" \
    -scheme "$name" -configuration Debug -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${INTERACTIONS_DERIVED_DATA:-$root/.build/DerivedData}" \
    -jobs 2 CODE_SIGNING_ALLOWED=NO build
