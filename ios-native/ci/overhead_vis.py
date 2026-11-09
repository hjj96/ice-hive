#!/usr/bin/env python3
"""The overhead's visibility gate (Stage 1 R3; design.md §1.1.2 «Occlusion budget» / «nothing may hide the squad»).

The app measures it itself with `-ohVis` (App/Sources/Metal/Level/OverheadVisibility.swift: an offscreen mask of the game
camera's view — the walkable deck, a silhouette proxy per marine, the overhead in front of them with its exact cutaway —
read back twice a second) and logs `oh vis t=… deck=… px covered …% solid …% | marines px …/…/…/… hidden …%` per sample
and `oh vis summary samples=N deck mean …% worst …% marine hidden worst …% → ok|FAIL (…)` after each. This reads the
logs of the runs given, prints a table and fails (exit 1) when a run has no samples or its last summary fails:
  deck covered   mean ≤ 15 %, worst sample ≤ 25 % (the 25 % ghost of the cutaway counts a quarter)
  marine hidden  ≤ 5 % of any marine's proxy pixels behind solid overhead, in every sample

Usage: overhead_vis.py <results dir> <label> [<label> ...]   (reads <results>/app-<label>.log)
"""
import os
import re
import sys

rx_sample = re.compile(r'oh vis t=([0-9.]+) deck=(\d+) px covered ([0-9.]+)% solid ([0-9.]+)% \| marines px ([0-9/]+) hidden ([0-9./]+)%')
rx_summary = re.compile(r'oh vis summary samples=(\d+) deck mean ([0-9.]+)% worst ([0-9.]+)% marine hidden worst ([0-9.]+)% → (ok|FAIL.*)$')


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    res, labels = sys.argv[1], sys.argv[2:]
    bad = []
    print('OVERHEAD VISIBILITY (ci/overhead_vis.py; the app\'s -ohVis mask: deck covered mean ≤ 15 %, worst ≤ 25 %, no marine > 5 % hidden)')
    for lb in labels:
        p = os.path.join(res, f'app-{lb}.log')
        if not os.path.exists(p):
            print(f'  {lb}: no log')
            bad.append(f'{lb}: no log')
            continue
        samples, summary = [], None
        for line in open(p, errors='replace'):
            m = rx_sample.search(line)
            if m:
                samples.append((float(m.group(1)), int(m.group(2)), float(m.group(3)), float(m.group(4)), m.group(5), m.group(6)))
            s = rx_summary.search(line.rstrip())
            if s:
                summary = s
        if not samples or summary is None:
            print(f'  {lb}: no «oh vis» samples')
            bad.append(f'{lb}: no samples')
            continue
        for t, px, cov, solid, mpx, hid in samples:
            print(f'  {lb:16s} t={t:5.1f}s deck {px:6d} px covered {cov:5.1f} % (solid {solid:5.1f} %)  marines px {mpx}  hidden {hid} %')
        verdict = summary.group(5)
        print(f'  {lb:16s} SUMMARY {summary.group(1)} samples: deck mean {summary.group(2)} %, worst {summary.group(3)} %, marine hidden '
              f'worst {summary.group(4)} % → {verdict}')
        if verdict != 'ok':
            bad.append(f'{lb}: {verdict}')
    print('OVERHEAD VISIBILITY GATE: ' + ('passed' if not bad else 'FAILED — ' + ' | '.join(bad)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
