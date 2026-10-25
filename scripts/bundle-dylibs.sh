#!/bin/sh
# bundle-dylibs.sh: make rlvm.app run where Homebrew never existed.
#
# Every third-party dylib moves into Contents/Frameworks and every load
# command is repointed at @rpath. otool only sees load commands, so
# libraries that arrive through a bare dlopen() -- sdl12-compat's SDL3
# backend -- are passed to us explicitly as extra arguments.
#
#   usage: bundle-dylibs.sh <executable-inside-bundle> [extra-dylib ...]

set -eu

BIN="$1"; shift
FW="$(dirname "$BIN")/../Frameworks"
# This directory belongs to this script alone: start it fresh, so no copy
# from an older policy -- carrying attributes we would now refuse -- can
# outlive the policy that made it.
rm -rf "$FW"
mkdir -p "$FW"

is_third_party() {
  case "$1" in
    /System/*|/usr/lib/*|@*) return 1 ;;
    *) return 0 ;;
  esac
}

# Copy <path> into Frameworks and give it an @rpath identity, once.
# -X: leave the source's extended attributes behind -- brew dylibs carry a
# system-managed com.apple.provenance that not even root may clear, and a
# fresh signature wants a clean slate anyway.
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

# Rewriting load commands invalidates signatures; make everything ad-hoc
# valid again so Gatekeeper has nothing to complain about locally.
# codesign signing anything inside the .app scans the whole bundle and
# refuses files still carrying Finder metadata. It signs right over
# com.apple.provenance -- the kernel re-attaches that to freshly created
# Mach-O images no matter what a copy does -- so clear exactly the two
# attributes it actually minds, and forgive whichever are absent.
BUNDLE="$(dirname "$BIN")/../.."
for image in $(find "$BUNDLE" -type f); do
  xattr -d com.apple.FinderInfo "$image" 2>/dev/null || true
  xattr -d com.apple.ResourceFork "$image" 2>/dev/null || true
done
# The bundle directory itself: macOS hangs FinderInfo on directories as it
# pleases, and codesign scanning the bundle root names it as disallowed
# data. provenance it never mentions, and signs right over -- leave it be.
xattr -d com.apple.FinderInfo "$BUNDLE" 2>/dev/null || true
for lib in "$FW"/*; do codesign --force --sign - "$lib"; done
codesign --force --sign - "$BIN"

echo "bundle-dylibs: $(ls "$FW" | wc -l | tr -d ' ') libraries brought home."
