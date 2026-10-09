#!/usr/bin/env bash
# Opens the Debug WhisperNative.app built from this checkout. Every checkout and
# worktree gets its own DerivedData dir, so match on the project it was built from.
set -euo pipefail

project="$PWD/WhisperNative.xcodeproj"
for derived in ~/Library/Developer/Xcode/DerivedData/WhisperNative-*; do
  if [ "$(plutil -extract WorkspacePath raw "$derived/info.plist" 2>/dev/null)" = "$project" ]; then
    open "$derived/Build/Products/Debug/WhisperNative.app"
    exit 0
  fi
done
echo "error: no DerivedData build for $project" >&2
exit 1
