# Инструменты ассетов «Ледяного Улья» v2.0

Скрипты, которые превращают арт и звук веб-версии (`game/js/01…09`) в ресурсы для нативной SpriteKit-версии.
Всё рендерится из **исходников самой игры**: те же построители геометрии, материалы, канвас-текстуры и синтез
звука, запущенные в headless Chromium (Playwright + SwiftShader WebGL). Работает на Linux и macOS.

```sh
npm ci                                       # в корне репозитория: three@0.170.0, playwright
npx playwright install chromium              # если браузер ещё не скачан
node ios-native/tools/render-sprites.mjs     # все спрайты (≈ 6 мин)
node ios-native/tools/render-sprites.mjs --only marines,level   # только часть: bugs, corpses, marines, props, fx, level, bg
node ios-native/tools/render-audio.mjs       # все звуки (≈ 5 с)
node ios-native/tools/fetch-fonts.mjs        # шрифты Oswald / JetBrains Mono (npm pack)
```

Результат:

| Что | Куда |
| --- | --- |
| текстурные атласы (`*.spriteatlas`, у каждого кадра @2x/@3x) | `App/Resources/Assets.xcassets/` |
| описание всех наборов: проекция, якоря, имена кадров, направления, fps, слои, правила сборки уровня | `App/Resources/sprites-manifest.json` |
| звуки (WAV 44.1 кГц моно, нормализованы к −1 dBFS) + `sounds-manifest.json` (громкость, интервалы, петли) | `App/Resources/Sounds/` |
| шрифты TTF + лицензии OFL + `fonts.json` (PostScript-имена) | `App/Resources/Fonts/` |
| контактные листы для проверки (не в git) | `tools/out/sheets/` |
| маленькие превью по группам и тестовая сборка уровня из тайлов | `tools/previews/` |

## Главное о проекции

Ортографическая камера с теми же углами, что у веб-камеры: рыскание 45°, наклон 57°. Масштаб **24 pt на метр**
(72 px/м в @3x). Экранные координаты точки мира:

```
u = (x − z) · 0.707107 · 24          // вправо
v = (y · 0.544639 − (x + z) · 0.593030) · 24   // вверх
глубина (zPosition) = (x + z) · 0.385118 + y · 0.838671
```

16 направлений: `dir = Int((atan2(dx, dz) / 2π · 16).rounded()) & 15` (0 — к +z, вниз-влево на экране).
Плоские текстуры (`Ground`) нарисованы «сверху»: контейнер с `yScale = 0.838671`, у спрайта `zRotation = r − π/4`.

Спрайты освещены ярким «полным» светом; темноту ночной станции нативная игра накладывает сама (умножение на карту
света), а светящиеся части лежат отдельными слоями `*Glow` для `blendMode = .add`.

## Файлы

- `render-sprites.mjs` — точка входа спрайтов; группы `bugs`, `corpses`, `marines`, `props` описаны в нём,
  `fx`, `level`, `bg` — в `lib/fx.mjs`, `lib/level.mjs`, `lib/background.mjs`.
- `lib/gamepage.mjs` — загружает части игры одним модулем в Chromium и дописывает к ним код инструментов
  (`lib/inpage-*.js` выполняются в области видимости игры и вызывают её функции напрямую).
- `lib/pipeline.mjs` — рендер набора кадров с суперсэмплингом, общая обрезка, @3x/@2x, слой свечения, манифест.
- `lib/level.mjs` — тайловый набор станции и `assembly()` — эталонная сборка мини-станции из тайлов по правилам
  `manifest.level` (результат: `previews/level_assembly.png`).
- `render-audio.mjs` + `lib/inpage-audio.js` — рецепты `sfx()` и фоновые петли `audioInit()` через
  `OfflineAudioContext` с детерминированным шумом.
- `fetch-fonts.mjs` — TTF из пакетов `@expo-google-fonts/*`.
