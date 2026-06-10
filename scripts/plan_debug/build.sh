#!/usr/bin/env bash
set -euo pipefail

# Compiles the engine sources plus the CLI into a standalone binary with
# swiftc — no Xcode, no SPM, no simulator. This is how the test suite drives
# the generator (it parses the CLI's output). The library itself builds with
# `swift build`; this is only for the CLI + tests.
#
# API.swift is left out on purpose: its sample-catalog loader uses
# Bundle.module, which only exists in an SPM build. The CLI loads its catalog
# from a file path instead.
#
# Usage:
#   ./scripts/plan_debug/build.sh
#   ./scripts/plan_debug/plan_debug            # summary
#   ./scripts/plan_debug/plan_debug dump 21K   # per-week dump, filtered

cd "$(dirname "$0")/../.."

OUTPUT="scripts/plan_debug/plan_debug"

echo "Compiling plan_debug..."
swiftc \
  -framework Foundation \
  -framework SwiftUI \
  -O \
  -o "$OUTPUT" \
  Sources/TrainingPlanKit/Models/*.swift \
  Sources/TrainingPlanKit/Engine/*.swift \
  Sources/TrainingPlanKit/Pacing/*.swift \
  Sources/TrainingPlanKit/Support/*.swift \
  scripts/plan_debug/main.swift

echo "Built: $OUTPUT"
