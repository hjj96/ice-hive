# Ледяной Улей 2.0 — нативная версия (Swift + SpriteKit)

Нативный порт веб-игры (three.js, папка `game/`) на Swift + SpriteKit. Веб-версия — эталон и спецификация:
тот же геймплей, тот же русский интерфейс, тот же визуальный стиль.

## Сборка на Mac

```bash
brew install xcodegen
cd ios-native
xcodegen generate
open IceHive.xcodeproj
```

В Xcode: таргет **IceHive** → *Signing & Capabilities* → выберите свою **Team**, затем запустите на iPhone или симуляторе (⌘R).

Проект `IceHive.xcodeproj` генерируется из `project.yml` и в git не хранится — после изменения `project.yml`
или добавления файлов снова выполните `xcodegen generate`.

Аргументы запуска (Edit Scheme → Run → Arguments):

| Аргумент | Что делает |
|---|---|
| `-demo combat` | миссия штурмовиком, отряд неуязвим, автопилот, 600 жуков вокруг — их число держится около 600 |
| `-demo beacon` | миссия, отряд у маяка «Альфа», толпа жуков |
| `-demo title` | титульный экран (за ним — станция в режиме демонстрации) |
| `-demo calm` | начало миссии без жуков (режиссёр выключен): освещение и вид станции |
| `-demo smoke` | то же, что `combat` |
| `-seconds N` | через N секунд после окончания загрузки пишет в лог `demo done … avgFps=… minFps=… worstFrame=…` (первая секунда в статистику не входит) |
| `-debugHUD` | отладочная панель (fps, время симуляции и отрисовки, жуки на экране, частицы, узлы) |
| `-class assault\|pyro\|cryo\|gunner`, `-seed N`, `-mute`, `-orient portrait\|landscape` | класс, сид, без звука, фиксированная ориентация |
| `-nolight` | диагностика: без слоя темноты и фонарей |

Управление: левая половина экрана — плавающий стик бега, правая — прицел и огонь, кнопки способности и рывка справа.
С клавиатуры (симулятор): WASD/стрелки — бег, IJKL — прицел и огонь, пробел — рывок, Q/E — способность, Esc — пауза.

## Структура

| Путь | Что это |
|---|---|
| `project.yml` | спецификация XcodeGen (iOS 16+, только iPhone, bundle id `com.hjj96.icehive`, версия 2.0.0) |
| `IceHiveCore/` | Swift-пакет с чистой игровой логикой (только Foundation + simd), тесты: `cd IceHiveCore && swift test` |
| `App/Sources/App/` | AppDelegate, SceneDelegate, `GameViewController` (SKView, клавиатура), аргументы запуска, лог |
| `App/Sources/Game/` | `GameScene` — единственная сцена: фиксированный шаг 60 Гц с аккумулятором, события ядра, режимы (титул / миссия / карты улучшений / пауза / отчёт); `DemoScript` — сценарии CI |
| `App/Sources/Render/` | `Iso` (ортопроекция 3/4 из манифеста, z-слои), `SpriteAssets` (листы спрайтов + манифест), `WorldRenderer` и слои `LevelLayer` (станция из тайлов), `BugLayer`, `MarineLayer`, `FxLayer` + `GroundFx` + `Particles` (эффекты, пятна, трупы, телеграфы), `LightingLayer` (темнота и фонари — SKShader), `CameraController` |
| `App/Sources/UI/` | HUD (счёт, задача, отряд, броня, кнопки, стики, баннеры, таблички над бойцами), экраны титула / улучшений / паузы / отчёта |
| `App/Sources/Input/` | двойные стики (мультитач) и клавиатура |
| `App/Sources/Audio/` | звук на AVAudioPlayer по `Sounds/sounds-manifest.json` |
| `App/Resources/` | `Sheets/` (пять листов спрайтов + `sheets.json`), `sprites-manifest.json`, `Assets.xcassets` (иконка), `Info.plist`, `PrivacyInfo.xcprivacy`, `LaunchScreen.storyboard`, шрифты, звуки |
| `art/Sprites/` | исходные кадры (`*.spriteatlas`, @2x/@3x) — результат `tools/render-sprites.mjs`, в приложение не входят |
| `tools/` | node-скрипты, которые пре-рендерят ассеты из веб-игры и пакуют листы (`pack-sheets.mjs`) |
| `ci/` | вспомогательные скрипты CI |

## CI

`.github/workflows/native-ios.yml` запускается на push в ветки `native*` (macOS-раннер GitHub): `swift test` для ядра,
сборка под симулятор, затем на симуляторе по очереди `-demo combat`, `beacon`, `title`, `calm`, `combat` в альбомной ориентации
и `combat -nolight` (без слоя темноты — для сравнения стоимости шейдера) со скриншотами. Время скриншотов отсчитывается от строки `scene ready` (конец загрузки). Результаты коммитятся в ветку
`ci-results` в папку `<ветка>/<короткий sha>/` (`status.json`, `build.log`, `core-tests.log`, `bundle.txt`,
`combat-4s.png` … `landscape-9s.png`, `app-<демо>.log`, `fps.txt`, `loading.txt`, `alive.txt`, `app.log`).
Сборка в CI — конфигурация Debug, но с оптимизацией Swift (`SWIFT_OPTIMIZATION_LEVEL=-O`) и только arm64: так fps на
симуляторе ближе к реальному. Строки `hb` в `app-<демо>.log` — fps, время симуляции/отрисовки, жуки, частицы, память;
`hb ms` — разбивка кадра по разделам (мс).

## Спрайты и отрисовка

Все кадры лежат в пяти листах `App/Resources/Sheets/sheet_*.png` (≈ 40 Мпикс, 150 МБ в памяти после декодирования),
сгруппированных по слою отрисовки: `bugs` (жуки, тени, трупы), `squad` (бойцы, пропы, ящики, фонари, перила),
`glow` (все аддитивные светящиеся слои), `level` (тайлы пола, юбки, опоры, фон), `fx` (плоские текстуры и частицы).
Кадры в @2x и обрезаны по видимым пикселям; `sheets.json` хранит прямоугольник кадра в листе и его смещение в полном
кадре, поэтому якоря и размеры из `sprites-manifest.json` работают без изменений (`SKSpriteNode.show`).
Спрайты одного листа с одинаковым `zPosition` SpriteKit рисует одним вызовом: жуки и предметы на палубе
округляют глубину до целых слоёв (`ZBand.slice`), полы — до шагов по 0.25 м высоты.
После изменения кадров: `node ios-native/tools/render-sprites.mjs` (сам вызывает `pack-sheets.mjs`) или только
переупаковка: `node ios-native/tools/pack-sheets.mjs`.

Темнота — один полноэкранный спрайт с `SKShader` (`LightingLayer`), умножающий картинку на карту света: окружение
≈ 0.27/0.32/0.43 яркости заранее освещённых спрайтов, конусы четырёх фонарей и до шести точечных источников
(вспышки, огнемёт, напалм, маяк). Настройки сверены со скриншотами веб-версии того же места.
