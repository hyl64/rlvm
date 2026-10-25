#!/bin/sh
# bundle-dylibs.sh: make rlvm.app run where Homebrew never existed.
#
#   usage: bundle-dylibs.sh <freshly-built-rlvm-static> <bundle-dir> [extra-dylib ...]
#
# The script owns the two places it writes -- Contents/MacOS/rlvm and
# Contents/Frameworks -- and rebuilds both from the built binary on every
# run, so no rewritten load command from a previous pass can linger. Every
# third-party dylib moves into Frameworks with its loads repointed at
# @rpath. otool only sees load commands, so libraries that arrive through
# a bare dlopen() -- sdl12-compat's SDL3 backend -- are passed explicitly
# as extra arguments.

set -eu

SRC="$1"; BUNDLE="$2"; shift 2
FW="$BUNDLE/Contents/Frameworks"
BIN="$BUNDLE/Contents/MacOS/$(basename "$SRC")"

rm -rf "$FW"
mkdir -p "$FW"
cp -LX "$SRC" "$BIN"

is_third_party() {
  case "$1" in
    /System/*|/usr/lib/*|@*) return 1 ;;
    *) return 0 ;;
  esac
}

# Copy <path> into Frameworks and give it an @rpath identity, once.
# -X: leave the source's extended attributes behind; a fresh signature
# wants a clean slate.
copy() {
  path="$1"
  name="$(basename "$path")"
  if [ ! -f "$FW/$name" ]; then
    cp -LX "$path" "$FW/$name"
    install_name_tool -id "@rpath/$name" "$FW/$name"
  fi
}

# Seed with the binary's own third-party loads plus the dlopen-only extras.
for dep in $(otool -L "$BIN" | awk 'NR>1 {print $1}') "$@"; do
  if is_third_party "$dep"; then
    copy "$dep"
  fi
done

# And with whatever those libraries themselves load.
for lib in "$FW"/*; do
  for dep in $(otool -L "$lib" | awk 'NR>1 {print $1}'); do
    if is_third_party "$dep"; then
      copy "$dep"
    fi
  done
done

# Repoint every load command at what we just brought home.
repoint() {
  image="$1"
  for dep in $(otool -L "$image" | awk 'NR>1 {print $1}'); do
    if is_third_party "$dep"; then
      install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$image"
    fi
  done
}
repoint "$BIN"
for lib in "$FW"/*; do repoint "$lib"; done

# codesign signing inside the .app scans the whole bundle and refuses
# files still carrying Finder metadata. It signs right over
# com.apple.provenance -- the kernel re-attaches that to freshly created
# files no matter what a copy does -- so clear exactly the two attributes
# it minds, forgive whichever are absent, and drop the one hanging on the
# bundle directory itself.
for image in $(find "$BUNDLE" -type f); do
  xattr -d com.apple.FinderInfo "$image" 2>/dev/null || true
  xattr -d com.apple.ResourceFork "$image" 2>/dev/null || true
done
xattr -d com.apple.FinderInfo "$BUNDLE" 2>/dev/null || true
for lib in "$FW"/*; do codesign --force --sign - "$lib"; done
codesign --force --sign - "$BIN"

echo "bundle-dylibs: $(ls "$FW" | wc -l | tr -d ' ') libraries brought home."
