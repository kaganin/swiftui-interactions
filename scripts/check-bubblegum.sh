#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$root/Experiments/Bubblegum/Sources"
checks_dir="$root/Experiments/Bubblegum/Checks"
check_output="$(mktemp -d "${TMPDIR:-/tmp}/bubblegum-checks.XXXXXX")"
trap 'rm -rf "$check_output"' EXIT
run_check() {
    local name="$1"
    shift
    xcrun swiftc -O "$@" "$checks_dir/$name.swift" -o "$check_output/$name"
    "$check_output/$name"
}
run_check BlowDetector "$source_dir/GumBlowDetector.swift"
run_check Rupture "$source_dir/GumRupture.swift"
run_check Sway "$source_dir/GumSway.swift"
run_check Fragments "$source_dir/GumSurfaceGeometry.swift" "$source_dir/GumFragments.swift"
