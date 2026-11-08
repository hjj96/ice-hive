# Credits — third-party data and assets in ICE HIVE

Everything not listed here (code, models, textures, sounds, effects) is the project's own.

## Motion capture (the marines' locomotion, idles and turns)

The squad's walk, run, idle and turn-on-the-spot clips are retargeted from motion capture by the asset pipeline
(`tools/blender/characters/mocap/`; the exact source ranges, download URLs and sha256 sums are in
`tools/blender/characters/mocap/SOURCES.md`). Only the baked clips ship in the app (`Characters/marine_*.ihv`); the
source files are build inputs and are never shipped or redistributed as data.

- **CMU Graphics Lab Motion Capture Database** — free for research and commercial use; the data may be included in
  commercially sold products but not resold, even in converted form. Acknowledgement:
  «The data used in this project was obtained from mocap.cs.cmu.edu. The database was created with funding from NSF
  EIA-0196217.»
  (BVH conversion of the database by B. Hahne, cgspeed.com, 2010; taken from the GitHub mirror `meshula/cmu-mocap`.)
- **100STYLE** — Ian Mason, Sebastian Starke, Taku Komura, «Real-Time Style Modelling of Human Locomotion via
  Feature-Wise Transformations and Local Motion Phases» (2022). Licensed under Creative Commons Attribution 4.0
  International (CC BY 4.0, https://creativecommons.org/licenses/by/4.0/). Attribution: «The 100STYLE Dataset - Ian
  Mason». Changes: Neutral-style cycles retargeted onto the marines' skeleton, stride-warped, re-timed, mirrored, with a
  rifle stance and procedural hand / foot placement layered on.
- **Quaternius — Universal Animation Library** — CC0 1.0 (public domain dedication); credited voluntarily. Used by the
  motion tools as reference; no shipped clip of the feel build's locomotion package is taken from it.

The same credits are in the string catalog (`credits.*` keys) for the in-game Settings › Credits panel and in the last
line of the App Store description (`store/app-store-en.md`).

## Fonts

Oswald and JetBrains Mono under the SIL Open Font License 1.1 — the licence texts ship in the app
(`App/Resources/Fonts/OFL-*.txt`).
