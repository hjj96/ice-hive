#!/bin/sh
# WP4 «Отряд» — the marines, called by tools/blender/build.sh as  characters/build.sh OUT WORK
#   OUT/Characters/marine_<class>.ihv (IHV1 v2 skinned + clip tracks), marine_normal.iht, marine_orm.iht
#   ../reports/characters.json (the gates: foot drift per locomotion clip, IK reach error per clip)
# The maps come from the committed 8-bit bake in characters/bake_src (an authoring step, like the kit's trim sheets:
# Cycles bakes are not bit-stable between hosts): BAKE_CHARACTERS=1 tools/blender/build.sh re-bakes them first.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$1
WORK=$2
PY=${BLENDER_PY:-$HERE/../venv/bin/python}
mkdir -p "$OUT/Characters" "$WORK" "$HERE/../reports"
BAKE=""
if [ -n "$BAKE_CHARACTERS" ]; then BAKE="--bake"; fi
"$PY" "$HERE/build_marines.py" "$WORK/out" $BAKE > "$WORK/characters.log" 2>&1 || { tail -30 "$WORK/characters.log"; exit 1; }
for f in marine_assault.ihv marine_pyro.ihv marine_cryo.ihv marine_gunner.ihv marine_normal.iht marine_orm.iht; do
  cp "$WORK/out/$f" "$OUT/Characters/$f"
done
cp "$WORK/out/characters_build.json" "$HERE/../reports/characters.json"
grep -h '^\[' "$WORK/characters.log" | grep -E 'triangles|textures|done' | tail -6
