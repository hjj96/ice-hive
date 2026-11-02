# Deprecated store files (1.x, Russian)

ICE HIVE 2.0 ships in English only. These files describe the earlier 1.x app (the web game in a Capacitor shell,
Russian, portrait and landscape) and stay in the repository as history and as a starting point for a later Russian
translation. Do not upload or publish any of them for 2.0.

| File | What it was | Replaced in 2.0 by |
|---|---|---|
| `store/app-store-ru.md` | Russian App Store listing of 1.x | `store/app-store-en.md` |
| `store/privacy-policy-ru.md`, `store/privacy-policy-ru.html` | Russian-first privacy policy of 1.x (was `privacy-policy.md` / `.html`) | `store/privacy-policy.md`, `store/privacy-policy.html` |
| `store/screenshots/6.3/`, `6.9/`, `6.5/` | 1.x screenshots of the web build | `store/screenshot-plan-en.md` → `store/screenshots-2.0/` (taken after the interface overhaul) |

The 1.x screenshots stay where they are because the web harness and the native swarm look reference still point at
`store/screenshots/6.3/2-swarm.png` (`harness/scenarios/native-ref.mjs`, `-demo swarmshot`).

Owner notes in Russian: «Ледяной Улей» 1.x — история. Для 2.0 используйте только английские файлы из таблицы.
