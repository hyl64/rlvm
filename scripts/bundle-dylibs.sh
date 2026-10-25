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
mkdir -p "$FW"

is_third_party() {
  case "$1" in
    /System/*|/usr/lib/*|@*) return 1 ;;
    *) return 0 ;;
  esac
}

# Copy <path> into Frameworks and give it an @rpath identity, once.
copy() {
  path="$1"
  name="$(basename "$path")"
  if [ ! -f "$FW/$name" ]; then
    cp -L "$path" "$FW/$name"
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
# SCons' file copies carry Finder metadata along, and codesign refuses to
# sign anything that still holds such detritus.
xattr -cr "$(dirname "$BIN")/../.."
for lib in "$FW"/*; do codesign --force --sign - "$lib"; done
codesign --force --sign - "$BIN"

echo "bundle-dylibs: $(ls "$FW" | wc -l | tr -d ' ') libraries brought home."
