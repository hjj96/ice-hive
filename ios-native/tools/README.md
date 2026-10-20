# Инструменты ассетов «Ледяного Улья» v2.0

Скрипты, которые превращают 3D-модели, текстуры и звук веб-версии (`game/js/01…09`) в ресурсы нативной версии
(Metal-рендер мира + SpriteKit-HUD). Всё берётся из **исходников самой игры**: те же построители геометрии,
канвас-текстуры и синтез звука, запущенные в headless Chromium (Playwright + SwiftShader WebGL). Работает на Linux и macOS.

```sh
npm ci                                       # в корне репозитория: three@0.170.0, playwright
npx playwright install chromium              # если браузер ещё не скачан
node ios-native/tools/export-meshes.mjs      # 3D-меши и процедурные текстуры для Metal-рендера (≈ 10 с)
node ios-native/tools/export-meshes.mjs --verify   # только проверка и контрольный рендер того, что уже на диске
node ios-native/tools/render-audio.mjs       # все звуки (≈ 5 с)
node ios-native/tools/fetch-fonts.mjs        # шрифты Oswald / JetBrains Mono (npm pack)
```

Результат:

| Что | Куда |
| --- | --- |
| меши `*.mesh` (IHM1), текстуры `tex_*.png`, `manifest.json` (материалы, цветовые пространства, заметки) | `App/Resources/Meshes/` |
| контрольный рендер выгруженных мешей (three.js только из файлов на диске) | `tools/previews/meshes_verify.png` |
| звуки (WAV 44.1 кГц моно, нормализованы к −1 dBFS) + `sounds-manifest.json` (громкость, интервалы, петли) | `App/Resources/Sounds/` |
| шрифты TTF + лицензии OFL + `fonts.json` (PostScript-имена) | `App/Resources/Fonts/` |

До версии на Metal мир рисовался SpriteKit-спрайтами, пре-рендеренными отсюда же (`render-sprites.mjs`,
`pack-sheets.mjs`, `art/Sprites/`); они удалены вместе с SpriteKit-рендером мира и остаются в истории git
(последний коммит с ними — `db58a09`).

## Конвейер Blender (`blender/`, `textures/astc.sh`)

Новые ассеты версии 2.0 — кит станции (`App/Resources/Kit`: детали `station.ihk`, трим-листы и атлас AO в ASTC),
затем жуки, бойцы и зонд окружения — строит headless Blender из Python: [`blender/README.md`](blender/README.md).
Выход детерминирован и коммитится; гейты ассетов — `python3 ios-native/tools/blender/gates.py`.

## Меши для Metal-рендера (`export-meshes.mjs`, уходит)

Экспортёр из веб-игры выводится из обращения по мере появления ассетов конвейера Blender: станция (`level_*`,
`lift_*`, `beacon_top`, текстуры `grating`, `slab`, `hazard`, `snow`) им больше не пишется — её заменил кит
(`RETIRED` в `export-meshes.mjs`); жуки, бойцы, трупы и мелкие предметы пока остаются отсюда.

Те же построители геометрии игры (`buildBugGeometry`, `buildMarineGeos`, уровень из `04-level.js`, турель / аптечка /
плевок / граната из `07-fx.js`) и те же канвас-текстуры `TEX.*` + маска снега, выгруженные как есть в
`App/Resources/Meshes/`: `<имя>.mesh`, `tex_<имя>.png`, `manifest.json` (формат, границы, заметки по материалам и
точкам вращения, параметры материалов игры). Формат `IHM1` (little-endian): `"IHM1"`, `u32` число вершин, `u32` число
индексов, `u32` флаги (бит 0 — есть свечение, бит 1 — `aLeg` с данными лап жука, бит 2 — в `aLeg.xy` лежит uv,
биты 8…15 — шаг вершины = 52), затем вершины по 52 байта плотно (`float3` позиция, `float3` нормаль, `float3` цвет в
линейном RGB, `float` aGlow, `float3` aLeg), затем `u32` индексы (треугольники, обход против часовой — как в three.js).
uv уже перевёрнуты под верхний левый угол картинки (Metal / PNG): PNG грузить без переворота. Метры, y вверх, мировые
координаты веб-игры; `level_*`/`lift_*` уже стоят на месте (лифт — на высоте покоя −6, при эвакуации поднимается
сдвигом), остальное — в пространстве модели.

Проверка: скрипт перечитывает каждый файл в node (размер, индексы, конечность, нормали, флаги) и сравнивает площадь
поверхности и «цвет × площадь» с исходной геометрией, измеренной в браузере до упаковки; затем рисует
`previews/meshes_verify.png` — three.js только из выгруженных файлов (весь уровень, крупный план площадки с жуками и
отрядом, ряд всех объектов). Выход детерминирован (повторный запуск даёт те же байты).

## Файлы

- `lib/gamepage.mjs` — загружает части игры одним модулем в Chromium и дописывает к ним код инструментов
  (`lib/inpage-*.js` выполняются в области видимости игры и вызывают её функции напрямую).
- `export-meshes.mjs` + `lib/inpage-meshes.js` (сбор геометрии в странице игры) + `lib/verify-meshes.js` (контрольный
  рендер на голом three.js из выгруженных файлов).
- `render-audio.mjs` + `lib/inpage-audio.js` — рецепты `sfx()` и фоновые петли `audioInit()` через
  `OfflineAudioContext` с детерминированным шумом.
- `fetch-fonts.mjs` — TTF из пакетов `@expo-google-fonts/*`.

Новые форматы вершин (скиннинг, текстуры вершинной анимации) — новый бит/шаг в `flags` формата IHM1 и свой
`MTLVertexDescriptor` в `MetalRenderer` (см. «Как строится кадр» в `ios-native/README.md`).
