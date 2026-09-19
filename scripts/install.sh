#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -gt 1 ]; then
    printf 'Usage: %s [applications-directory]\n' "$0" >&2
    exit 1
fi
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    printf 'Usage: %s [applications-directory]\n' "$0"
    printf 'Builds, installs or updates, and opens Switcheroo. Settings are preserved.\n'
    exit 0
fi

./scripts/build.sh
swift scripts/install-local.swift "$PWD/dist/Switcheroo.app" "$@"
