#!/bin/sh
# «Ледяной Улей» asset pipeline: headless Blender (pip bpy 5.2.2, Python 3.13 exactly), deterministic outputs committed
# under App/Resources, so the iOS CI never runs Blender. See README.md here.
#
#   python3.13 -m venv tools/blender/venv && tools/blender/venv/bin/pip install -r tools/blender/requirements.txt  (once)
#   tools/blender/build.sh             build everything into App/Resources, write assets.md5, run the gates
#   tools/blender/build.sh --verify    two clean builds into work/a and work/b must be byte-identical (md5), and equal
#                                      to what is committed; nothing is written into App/Resources
#   tools/blender/build.sh --renders   also the game-camera read-back renders (Cycles; the nightly job) → previews/
#   tools/blender/build.sh --bake-trims  re-bake the trim sheets in Cycles into kit/trims_src (an authoring step: the
#                                      bakes are not bit-stable, so the build encodes the committed 8-bit sources)
#   tools/blender/build.sh --bake-ao   re-bake the kit's AO atlas in Cycles into kit/ao_src (after any change to the
#                                      pieces' geometry: the build refuses a bake made for other geometry; Cycles
#                                      differs between CPUs, the committed 8-bit source does not). Both bake flags
#                                      may be given together.
#   BLENDER_PY=/path/to/python          another venv
# Steps: kit/build_kit.py (pieces, AO atlas from kit/ao_src, station.ihk, kit_ao.iht) → kit/trims.py (kit/trims_src → trim_*.iht) →
# creatures/, characters/, env/ build.sh when present (WP3 / WP4 / WP2 own them; each writes into $OUT/<Folder> and a
# gates report into reports/; without env/build.sh, env/bake_probe.py → Env/station_probe.ihe) → gates.py.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PY=${BLENDER_PY:-$HERE/venv/bin/python}
RES="$ROOT/App/Resources"
cd "$HERE"
if [ ! -x "$PY" ]; then echo "build.sh: no Blender venv at $PY (see the header)" >&2; exit 1; fi
BAKE=""
BAKE_AO=""
while :; do
  case "$1" in
    --bake-trims) BAKE="--bake"; shift ;;
    --bake-ao) BAKE_AO="--bake-ao"; shift ;;
    *) break ;;
  esac
done

build() {
  # $1: output root (gets Kit/ and the other asset folders), $2: work dir (sources, logs)
  out=$1; work=$2
  mkdir -p "$out/Kit" "$work"
  "$PY" kit/build_kit.py "$work/kit" --previews "$work/previews" $BAKE_AO > "$work/kit.log" 2>&1 || { tail -30 "$work/kit.log"; exit 1; }
  "$PY" kit/trims.py "$work/kit" --previews "$work/previews" $BAKE > "$work/trims.log" 2>&1 || { tail -30 "$work/trims.log"; exit 1; }
  for f in station.ihk kit_ao.iht trim_normal.iht trim_orm.iht; do cp "$work/kit/$f" "$out/Kit/$f"; done
  for d in creatures characters env; do
    if [ -x "$d/build.sh" ]; then BLENDER_PY="$PY" "$d/build.sh" "$out" "$work/$d"; fi
  done
  # WP2's environment probe (deterministic Cycles bake, ~15 s) until env/ has its own build.sh
  if [ ! -x env/build.sh ] && [ -f env/bake_probe.py ]; then
    mkdir -p "$out/Env"
    "$PY" env/bake_probe.py "$out/Env/station_probe.ihe" > "$work/env.log" 2>&1 || { tail -30 "$work/env.log"; exit 1; }
  fi
  grep -h '^\[' "$work/kit.log" "$work/trims.log" | grep -v 'Info' | tail -12
}

sums() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs md5sum 2>/dev/null || find . -type f | LC_ALL=C sort | xargs md5 -r); }

case "$1" in
  --verify)
    rm -rf work/a work/b
    build work/a/out work/a
    build work/b/out work/b
    sums work/a/out > work/a.md5
    sums work/b/out > work/b.md5
    if ! cmp -s work/a.md5 work/b.md5; then echo "VERIFY: two clean builds differ"; diff work/a.md5 work/b.md5; exit 1; fi
    echo "VERIFY: two clean builds are identical ($(wc -l < work/a.md5) files)"
    for f in $(cd work/a/out && find . -type f | LC_ALL=C sort); do
      if ! cmp -s "work/a/out/$f" "$RES/$f"; then echo "VERIFY: committed $f differs from a clean build"; exit 1; fi
    done
    echo "VERIFY: the committed assets equal a clean build"
    ;;
  *)
    rm -rf work/main
    build "$RES" work/main
    mkdir -p previews
    cp work/main/previews/*.png previews/ 2>/dev/null || true
    mkdir -p reports
    cp work/main/kit/kit_build.json work/main/kit/trims_build.json reports/
    if [ "$1" = "--renders" ]; then "$PY" readback_kit.py "$RES/Kit" previews/; fi
    "$PY" gates.py --write-manifest
    "$PY" gates.py
    ;;
esac
