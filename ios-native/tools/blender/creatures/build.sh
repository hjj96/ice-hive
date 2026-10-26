#!/bin/sh
# The swarm's creatures (WP3 «Рой»): one Blender build per bug type → <out>/Creatures/<type>.ihv (rigid IHV1 v2:
# 3 LODs, bone texture, glow table, sockets) + its gates report (reports/creature_<type>.json: rigid path vs the
# deformed mesh, planted-foot drift, IK reach error — gates.py checks them).
#   creatures/build.sh OUT_ROOT WORK_DIR          (tools/blender/build.sh calls it; BLENDER_PY = the venv's python)
#   creatures/build.sh OUT_ROOT WORK_DIR runner   (one type)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
PY=${BLENDER_PY:-$HERE/../venv/bin/python}
OUT="$1/Creatures"
WORK="$2"
mkdir -p "$OUT" "$WORK" "$HERE/../reports"
TYPES=${3:-"runner spitter brute boomer"}
for t in $TYPES; do
  if [ ! -f "$HERE/$t.py" ]; then continue; fi
  "$PY" "$HERE/build.py" "$t" "$OUT" "$WORK" > "$WORK/$t.log" 2>&1 || { tail -30 "$WORK/$t.log"; exit 1; }
  cp "$WORK/${t}_gates.json" "$HERE/../reports/creature_$t.json"
  grep -E 'LOD[0-9]: [0-9]+ tris|foot drift|wrote' "$WORK/$t.log" | sed "s/^/[$t] /"
done
