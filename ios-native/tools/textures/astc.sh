#!/bin/sh
# «Ледяной Улей» — the pinned ASTC encoder of the asset pipeline (ios-native/tools/blender/iht.py calls it).
#
#   tools/textures/astc.sh path                               # prints the astcenc binary (downloads it once)
#   tools/textures/astc.sh encode in.png out.astc 5x5 [-thorough] [-normal]
#                                                              # LDR linear (-cl), 2 threads, invariant output
#   tools/textures/astc.sh decode in.astc out.png               # back to PNG (read-back renders, reviews)
#
# astcenc 5.2.0 (Arm, Apache-2.0) from its GitHub release, checked against a pinned SHA-256 and cached in
# tools/textures/.cache/ (gitignored). The release builds are invariant: the same input gives the same blocks with
# any SIMD variant and thread count, so a texture build is byte-identical on Linux and macOS. On x86-64 the SSE4.1
# build is used (runs everywhere), on macOS the universal build. ASTCENC=/path/to/astcenc overrides the download.
set -e
VER=5.2.0
HERE=$(cd "$(dirname "$0")" && pwd)
CACHE="$HERE/.cache/astcenc-$VER"

fetch() {
  # $1 zip name, $2 sha256, $3 binary inside the zip
  mkdir -p "$CACHE"
  if [ ! -x "$CACHE/$3" ]; then
    url="https://github.com/ARM-software/astc-encoder/releases/download/$VER/$1"
    curl -fsSL -o "$CACHE/$1" "$url"
    got=$( (sha256sum "$CACHE/$1" 2>/dev/null || shasum -a 256 "$CACHE/$1") | cut -d' ' -f1)
    if [ "$got" != "$2" ]; then echo "astc.sh: checksum mismatch for $1 ($got)" >&2; rm -f "$CACHE/$1"; exit 1; fi
    (cd "$CACHE" && unzip -o -q "$1" && chmod +x bin/*)
  fi
  echo "$CACHE/$3"
}

bin() {
  if [ -n "$ASTCENC" ]; then echo "$ASTCENC"; return; fi
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) fetch "astcenc-$VER-linux-x64.zip" b8c805b3c4a32680287ad5e5fc2a8b5ddf78c80f24cc0ec7ed1e4eb03c6cc5d2 bin/astcenc-sse4.1 ;;
    Darwin-*) fetch "astcenc-$VER-macos-universal.zip" a4d1c37d1fd98db283eb3e1494cf8e727ad064c693a3aff4cc435aa30c8d5737 bin/astcenc ;;
    *) echo "astc.sh: no pinned astcenc for $(uname -s)-$(uname -m); set ASTCENC=/path/to/astcenc ($VER)" >&2; exit 1 ;;
  esac
}

case "$1" in
  path) bin ;;
  encode)
    shift
    B=$(bin)
    in=$1; out=$2; blk=$3; shift 3
    "$B" -cl "$in" "$out" "$blk" "$@" -j 2 -silent
    ;;
  decode)
    B=$(bin)
    "$B" -dl "$2" "$3" -silent
    ;;
  *) echo "usage: astc.sh path | encode in.png out.astc 5x5 [-thorough] [-normal] | decode in.astc out.png" >&2; exit 2 ;;
esac
