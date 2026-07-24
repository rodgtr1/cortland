#!/usr/bin/env bash
# Runs the whole suite — public app plus the private Pro package — in one
# `swift test`, and prints the combined count.
#
# SwiftPM does not run a dependency's tests, and it refuses a target path
# outside the package root, so the Pro test target is reached through a
# gitignored symlink at Tests/CortlandProTests. This script refreshes that link
# from CORTLAND_PRO_PATH, then hands off to swift test.
#
#   ./scripts/test-all.sh                        # links ../cortland-pro
#   CORTLAND_PRO_PATH=/elsewhere ./scripts/test-all.sh
#
# Without the Pro package, plain `swift test` runs the free suite on its own.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PRO_PATH="${CORTLAND_PRO_PATH:-$REPO_ROOT/../cortland-pro}"

if [[ ! -d "$PRO_PATH" ]]; then
    echo "No Pro package at $PRO_PATH — running the free suite only." >&2
    echo "Set CORTLAND_PRO_PATH to include the Pro tests." >&2
    exec swift test "$@"
fi

PRO_PATH="$(cd "$PRO_PATH" && pwd)"
PRO_TESTS="$PRO_PATH/Tests/CortlandProTests"

if [[ ! -d "$PRO_TESTS" ]]; then
    echo "error: $PRO_TESTS does not exist" >&2
    exit 1
fi

ln -sfn "$PRO_TESTS" Tests/CortlandProTests
echo "Linked Tests/CortlandProTests -> $PRO_TESTS"

export CORTLAND_PRO_PATH="$PRO_PATH"
exec swift test "$@"
