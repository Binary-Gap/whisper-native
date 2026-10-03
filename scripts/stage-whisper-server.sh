#!/usr/bin/env bash
# Stages the cmake-built whisper-server and its dylibs into
# external/whisper.cpp/build/bundle/, ready for Xcode to embed:
#   bundle/whisper-server          -> Contents/MacOS (Copy Files, sign on copy)
#   bundle/Frameworks/<dylibs>     -> Contents/Frameworks (Copy Files, sign on copy)
# Each dylib is a real file named after its install name (libwhisper.1.dylib),
# so the bundle needs no symlinks. Runs only when whisper:build does, so Xcode
# sees changed inputs and re-seals the app exactly when these files change.
set -euo pipefail

build_bin="external/whisper.cpp/build/bin"
bundle_dir="external/whisper.cpp/build/bundle"
frameworks_dir="$bundle_dir/Frameworks"

rm -rf "$bundle_dir"
mkdir -p "$frameworks_dir"

# @rpath dependencies of a Mach-O file, as bare file names.
rpath_deps() {
  otool -L "$1" | awk '/@rpath\// { sub("@rpath/", "", $1); print $1 }'
}

# Copy the transitive @rpath closure, starting from the server binary.
pending=$(rpath_deps "$build_bin/whisper-server")
while [ -n "$pending" ]; do
  next=""
  for name in $pending; do
    [ -f "$frameworks_dir/$name" ] && continue
    cp -L "$build_bin/$name" "$frameworks_dir/$name"
    next="$next $(rpath_deps "$frameworks_dir/$name")"
  done
  pending="${next# }"
done

cp "$build_bin/whisper-server" "$bundle_dir/whisper-server"

# Swap cmake's build-tree rpath (a checkout path) for bundle-relative ones.
# The server finds the dylibs in Contents/Frameworks; the dylibs find each other
# side by side.
install_name_tool -delete_rpath "$PWD/$build_bin" "$bundle_dir/whisper-server"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$bundle_dir/whisper-server"
for dylib in "$frameworks_dir"/*.dylib; do
  install_name_tool -delete_rpath "$PWD/$build_bin" "$dylib" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path" "$dylib"
done
