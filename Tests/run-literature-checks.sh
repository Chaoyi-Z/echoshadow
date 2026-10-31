#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
check_dir=$(mktemp -d /tmp/echoshadow-checks.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/cache" \
  "$project_dir/EchoShadow/Literature.swift" "$project_dir/Tests/LiteratureChecks.swift" \
  -o "$check_dir/literature-checks"
"$check_dir/literature-checks"
