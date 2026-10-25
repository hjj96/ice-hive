#!/usr/bin/env python3
"""Asset gates of the «Ледяной Улей» pipeline — run on every asset change (CI asset step) and at the end of build.sh.
Needs only Python 3 + numpy (no Blender): it checks the COMMITTED outputs.

  python3 ios-native/tools/blender/gates.py                 # everything; exit 1 on any failure
  python3 ios-native/tools/blender/gates.py --write-manifest # build.sh: record the md5 of every shipped output

Gates (plan §2):
  md5        every file in tools/blender/assets.md5 exists with that md5 (the committed binaries are exactly what the
             deterministic build produced; build.sh --verify proves two clean builds are byte-identical)
  kit        App/Resources/Kit/station.ihk parses; every piece within its triangle budget (kit/pieces.py), no
             degenerate / out-of-range triangle, unit normals; the kit ≤ 3 MB; the committed AO bake (kit/ao_src) was
             made for exactly this geometry (ihk.ao_fingerprint)
  textures   every .iht under App/Resources parses (level table, sizes, ASTC block rows); all textures ≤ 30 MB
  creatures  every *.ihv: LOD0 ≤ 3000, LOD1 ≤ 450, LOD2 ≤ 150 triangles; a rigid ship file ≤ 0.3 MB, all ≤ 1.5 MB;
             skinned meshes 8–10k triangles, weights summing to 255
  reports    tools/blender/reports/*.json written by the creature / character builds:
             rigid_vs_vat_m ≤ 0.001, foot_drift_m (per clip) ≤ 0.02, ik_err_m (per clip) ≤ 1e-4
  budget     new pipeline assets (Kit, Creatures, Characters, Env, Look, Grade, VFX folders) ≤ 40 MB
"""
import glob
import hashlib
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))          # ios-native/
RES = os.path.join(ROOT, 'App', 'Resources')
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, 'kit'))
import ihk  # noqa: E402
import iht  # noqa: E402
import ihv  # noqa: E402

MANIFEST = os.path.join(HERE, 'assets.md5')
NEW_ASSET_DIRS = ['Kit', 'Creatures', 'Characters', 'Env', 'Look', 'Grade', 'VFX']
KIT_MAX = 3 * 1024 * 1024
TEX_MAX = 30 * 1024 * 1024
NEW_MAX = 40 * 1024 * 1024
BUGS_MAX = int(1.5 * 1024 * 1024)

fails = []
notes = []


def fail(msg):
    fails.append(msg)


def md5(p):
    return hashlib.md5(open(p, 'rb').read()).hexdigest()


def shipped():
    out = []
    for d in NEW_ASSET_DIRS:
        for p in sorted(glob.glob(os.path.join(RES, d, '**', '*'), recursive=True)):
            if os.path.isfile(p):
                out.append(os.path.relpath(p, ROOT))
    return out


def gate_md5():
    if not os.path.exists(MANIFEST):
        fail('md5: tools/blender/assets.md5 missing (run build.sh)')
        return
    listed = {}
    for line in open(MANIFEST):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        h, rel = line.split(None, 1)
        listed[rel] = h
    for rel, h in listed.items():
        p = os.path.join(ROOT, rel)
        if not os.path.exists(p):
            fail(f'md5: {rel} listed but missing')
        elif md5(p) != h:
            fail(f'md5: {rel} differs from the build (edit the source and rebuild, never the binary)')
    for rel in shipped():
        if rel not in listed:
            fail(f'md5: {rel} is shipped but not produced by the build (assets.md5)')
    notes.append(f'md5: {len(listed)} files match the build')


def gate_kit():
    p = os.path.join(RES, 'Kit', 'station.ihk')
    if not os.path.exists(p):
        notes.append('kit: no station.ihk')
        return
    import pieces as P
    D = ihk.read(p)
    size = os.path.getsize(p)
    if size > KIT_MAX:
        fail(f'kit: station.ihk {size} bytes > {KIT_MAX}')
    total = 0
    for pc in D['pieces']:
        name = pc['name']
        tris = pc['triangles']
        total += tris
        budget = P.PIECES[name][3] if name in P.PIECES else None
        if budget is None:
            fail(f'kit: piece {name} is not defined in kit/pieces.py')
        elif tris > budget:
            fail(f'kit: {name} {tris} triangles > budget {budget}')
        I = pc['indices']
        V = pc['vertices']
        pos = V['pos'][:, :3].astype(np.float64)
        if not np.all(np.isfinite(pos)):
            fail(f'kit: {name} non-finite positions')
        a, b, c = pos[I[:, 0]], pos[I[:, 1]], pos[I[:, 2]]
        area = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1)
        if np.any(area < 1e-9):
            fail(f'kit: {name} {int(np.sum(area < 1e-9))} degenerate triangles')
        n = V['nrm'][:, :3].astype(np.float64) / 127.0
        ln = np.linalg.norm(n, axis=1)
        if np.any(np.abs(ln - 1) > 0.03):
            fail(f'kit: {name} {int(np.sum(np.abs(ln - 1) > 0.03))} non-unit normals')
        layer = V['extra'][:, 1]
        if np.any((layer >= D['layers']) & (layer != 255)):
            fail(f'kit: {name} uses a trim layer ≥ {D["layers"]}')
    notes.append(f'kit: {len(D["pieces"])} pieces, {total} triangles, {size / 1024:.0f} KB')
    # the AO atlas is encoded from the committed bake (kit/ao_src): it must have been baked for this geometry
    bj = os.path.join(HERE, 'kit', 'ao_src', 'bake.json')
    if not os.path.exists(bj) or not os.path.exists(os.path.join(HERE, 'kit', 'ao_src', 'kit_ao.png')):
        fail('kit: kit/ao_src (the committed AO bake) missing: run build.sh --bake-ao')
    else:
        fp = ihk.ao_fingerprint(D['pieces'], {n: P.PIECES[n][2] for n in P.PIECES})
        if json.load(open(bj)).get('fingerprint') != fp:
            fail('kit: kit/ao_src was baked for other geometry than the shipped station.ihk: run build.sh --bake-ao')
        else:
            notes.append('kit: the AO bake matches the shipped geometry')


def gate_textures():
    total = 0
    for p in sorted(glob.glob(os.path.join(RES, '**', '*.iht'), recursive=True)):
        try:
            T = iht.read(p)
        except AssertionError as e:
            fail(f'textures: {os.path.relpath(p, RES)}: {e}')
            continue
        total += T['bytes']
        if T['mips'] < 1 or T['layers'] < 1:
            fail(f'textures: {os.path.relpath(p, RES)}: no levels')
    if total > TEX_MAX:
        fail(f'textures: {total / 1048576:.1f} MB > {TEX_MAX / 1048576:.0f} MB')
    notes.append(f'textures: {total / 1048576:.2f} MB')


def gate_creatures():
    rigid_total = 0
    for p in sorted(glob.glob(os.path.join(RES, '**', '*.ihv'), recursive=True)):
        rel = os.path.relpath(p, RES)
        try:
            D = ihv.read(p)
        except AssertionError as e:
            fail(f'creatures: {rel}: {e}')
            continue
        if D['skinned']:
            t = D['lods'][0]['triangle_count']
            if not (ihv.SKINNED_TRIS[0] <= t <= ihv.SKINNED_TRIS[1]):
                fail(f'characters: {rel} LOD0 {t} triangles outside {ihv.SKINNED_TRIS}')
            w = D['lods'][0]['vertices']['weights'].astype(int).sum(1)
            if np.any(w != 255):
                fail(f'characters: {rel} {int(np.sum(w != 255))} vertices with weights not summing to 255')
            continue
        for k, L in enumerate(D['lods']):
            if L['triangle_count'] > ihv.LOD_TRIS[k]:
                fail(f'creatures: {rel} LOD{k} {L["triangle_count"]} triangles > {ihv.LOD_TRIS[k]}')
        if not (D['flags'] & ihv.HF_VAT):
            rigid_total += D['bytes']
            if D['bytes'] > ihv.RIGID_FILE_BYTES:
                fail(f'creatures: {rel} {D["bytes"]} bytes > {ihv.RIGID_FILE_BYTES}')
    if rigid_total > BUGS_MAX:
        fail(f'creatures: all rigid files {rigid_total} bytes > {BUGS_MAX}')
    notes.append(f'creatures: {rigid_total / 1024:.0f} KB of rigid files')


def gate_reports():
    for p in sorted(glob.glob(os.path.join(HERE, 'reports', '*.json'))):
        rel = os.path.relpath(p, HERE)
        R = json.load(open(p))
        g = R.get('gates', {})
        if 'rigid_vs_vat_m' in g and g['rigid_vs_vat_m'] > 0.001:
            fail(f'reports: {rel} rigid vs VAT {g["rigid_vs_vat_m"] * 1000:.2f} mm > 1 mm')
        for clip, v in (g.get('foot_drift_m') or {}).items():
            if v > 0.02:
                fail(f'reports: {rel} foot drift in {clip} {v * 100:.1f} cm > 2 cm per stride')
        for clip, v in (g.get('ik_err_m') or {}).items():
            if v > 1e-4:
                fail(f'reports: {rel} IK reach error in {clip} {v * 1000:.2f} mm > 0')


def gate_budget():
    total = sum(os.path.getsize(os.path.join(ROOT, rel)) for rel in shipped())
    if total > NEW_MAX:
        fail(f'budget: new assets {total / 1048576:.1f} MB > {NEW_MAX / 1048576:.0f} MB')
    notes.append(f'budget: new assets {total / 1048576:.2f} MB of {NEW_MAX / 1048576:.0f} MB')


def write_manifest():
    lines = ['# md5 of every file the asset pipeline ships (tools/blender/build.sh writes it; gates.py checks it)']
    for rel in shipped():
        lines.append(f'{md5(os.path.join(ROOT, rel))}  {rel}')
    open(MANIFEST, 'w').write('\n'.join(lines) + '\n')
    print(f'assets.md5: {len(lines) - 1} files')


def main():
    if '--write-manifest' in sys.argv:
        write_manifest()
        return 0
    for g in (gate_md5, gate_kit, gate_textures, gate_creatures, gate_reports, gate_budget):
        g()
    for n in notes:
        print('  ' + n)
    if fails:
        print('ASSET GATES: FAILED')
        for f in fails:
            print('  FAIL ' + f)
        return 1
    print('ASSET GATES: passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
