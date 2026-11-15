#!/usr/bin/env bash
#
# The example gate. It is a BUILD gate. The `examples` job of the shared workflow
# (swissarmyhammer/workflows swift-ci.yaml, called from .github/workflows/ci.yml) runs this
# script, one example per matrix leg. Run it before you push and you know what CI will say.
#
# WHAT THIS GATE COVERS. Each example is a SwiftPM executable target of this package
# (`Examples/<Name>/`). The gate builds each target with `swift build --target <Name>`, thus
# a change to the public API that breaks an example fails here. The examples have no Xcode
# project and no application bundle, thus the gate regenerates no project and runs no UI test.
#
# WHAT THIS GATE DOES NOT COVER. It does not run an example: an example needs an on-device
# model and a repository to index. When a test target named `<Name>Tests` exists, the gate
# also runs it with `swift test --filter <Name>Tests`. At this time no example has one.
#
# Written for the bash 3.2 that ships with macOS, not bash 4+.
#
# Usage: Scripts/test-examples.sh [Name ...]
#   With no argument every example in EXAMPLES builds; with arguments only those build.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# Every example target. The `examples` input in .github/workflows/ci.yml names the same set.
# `IndexBenchmark` is not in this set: it is a local benchmark with a real MLX model, not an
# example of the API. The whole-package `swift build --build-tests` of the unit job builds it.
EXAMPLES=(
    CodeContextExample
    ManagerExample
)
readonly EXAMPLES

# Builds one example target, then runs its test target when it has one.
# Returns non-zero when the example has no folder, or when the build or a test fails.
run_example() {
    local name="$1"
    local source_dir="$REPO_ROOT/Examples/$name"
    local test_dir="$REPO_ROOT/Tests/${name}Tests"

    if [ ! -d "$source_dir" ]; then
        echo "error: no example named $name — expected $source_dir" >&2
        return 1
    fi

    echo "==> $name: swift build --target $name"
    swift build --package-path "$REPO_ROOT" --target "$name"

    if [ -d "$test_dir" ]; then
        echo "==> $name: swift test --filter ${name}Tests"
        swift test --package-path "$REPO_ROOT" --filter "${name}Tests"
    fi
}

main() {
    local selected=("$@")
    if [ $# -eq 0 ]; then
        selected=("${EXAMPLES[@]}")
    fi

    local failed=""
    local name
    for name in "${selected[@]}"; do
        if run_example "$name"; then
            echo "PASS $name"
        else
            echo "FAIL $name"
            failed="$failed $name"
        fi
    done

    if [ -n "$failed" ]; then
        echo
        echo "Example gate failed for:$failed"
        return 1
    fi

    echo
    echo "Example gate passed."
}

main "$@"
