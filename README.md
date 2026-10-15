# Ледяной Улей — iOS-приложение

«Ледяной Улей» — шутер с видом сверху про отряд из четырёх бойцов против роя. Вы управляете одним бойцом, трое напарников — ИИ. Игра написана на three.js r170 и существует в двух видах из одних исходников:

- **веб-артефакт** — один HTML-файл для claude.ai (`npm run build:artifact` → `dist/artifact.html`);
- **iOS-приложение** — та же игра внутри Capacitor 8 (`npm run build` → `www/`, затем `npx cap sync ios` → проект Xcode в `ios/`).

Ниже пошаговая инструкция для Mac: от первого запуска до публикации в App Store и выпуска обновлений.

---

## Содержание

1. [Что где лежит](#1-что-где-лежит)
2. [Требования](#2-требования)
3. [Первая настройка](#3-первая-настройка)
4. [Подпись в Xcode](#4-подпись-в-xcode)
5. [Запуск на iPhone](#5-запуск-на-iphone)
6. [Автотесты](#6-автотесты)
7. [Карточка приложения в App Store Connect](#7-карточка-приложения-в-app-store-connect)
8. [Архив и загрузка сборки](#8-архив-и-загрузка-сборки)
9. [TestFlight: внутреннее тестирование](#9-testflight-внутреннее-тестирование)
10. [Заполнение карточки](#10-заполнение-карточки)
11. [Отправка на проверку](#11-отправка-на-проверку)
12. [Частые причины отказа](#12-частые-причины-отказа)
13. [Как выпустить обновление](#13-как-выпустить-обновление)
14. [Веб-артефакт](#14-веб-артефакт)
15. [Решение проблем](#15-решение-проблем)

---

## 1. Что где лежит

| Путь | Что это |
|---|---|
| `game/head.html` | Разметка и CSS игры (HUD, меню, экраны) |
| `game/js/01-core.js` … `12-main.js` | Код игры. Части склеиваются по порядку в один модуль |
| `native/bridge.js` | Мост к iOS: вибрация, сохранение настроек, заставка, пауза при сворачивании. В браузере ничего не делает |
| `scripts/build-www.mjs` | Сборка `www/` для iOS (esbuild, target `safari15`, three.js внутри бандла, шрифты локально) |
| `scripts/build-artifact.mjs` | Сборка однофайлового артефакта `dist/artifact.html` с проверкой правил платформы |
| `harness/` | Автотесты: Playwright + Chromium с программным WebGL (SwiftShader) |
| `harness/scenarios/store-shots.mjs` | Сценарий, который снимает скриншоты для App Store |
| `capacitor.config.json` | Настройки Capacitor: `appId` `com.hjj96.icehive`, имя, цвета, заставка, статус-бар |
| `ios/App/App.xcodeproj` | Проект Xcode (Swift Package Manager, `.xcworkspace` нет) |
| `ios/App/App/Info.plist`, `PrivacyInfo.xcprivacy` | Настройки приложения и манифест конфиденциальности |
| `ios/App/App/Assets.xcassets` | Иконка (`AppIcon-1024.png`) и картинка заставки |
| `resources/` | Иконка и заставка (`icon.png` 1024×1024, `splash.png` 2732×2732); их исходники и генератор — в `resources/src/` |
| `store/app-store-ru.md` | Все тексты для App Store Connect с подсчётом символов (проверка: `npm run check:store`) |
| `store/screenshots/6.3/`, `6.9/`, `6.5/` | Скриншоты для App Store |
| `store/privacy-policy.html`, `.md` | Политика конфиденциальности (её нужно опубликовать) |
| `www/`, `dist/` | Результаты сборки, в git не попадают |

Команды из `package.json`:

| Команда | Что делает |
|---|---|
| `npm run build` | Собирает `www/` |
| `npm run sync` | `build` + `npx cap sync ios` (копирует `www/` в `ios/App/App/public` и обновляет плагины) |
| `npm run ios` | `sync` + открывает проект в Xcode |
| `npm run build:artifact` | Собирает `dist/artifact.html` |
| `npm test` | Собирает `www/` и прогоняет короткий тест игры |
| `npm run test:native` | Тест iOS-моста в имитации оболочки Capacitor |
| `npm run test:artifact` | Собирает артефакт и прогоняет тест |
| `npm run check:store` | Проверяет длины текстов в `store/app-store-ru.md` (ключевые слова — в байтах) и запрещённые слова |

## 2. Требования

- **Mac** с macOS, на которой запускается нужная версия Xcode.
- **Xcode 26 или новее** из Mac App Store (обязательно для загрузки в App Store: с апреля 2026 года Apple принимает только сборки на iOS 26 SDK; архив из Xcode 16 будет отклонён при загрузке). Apple периодически поднимает это требование, поэтому перед загрузкой проверьте актуальное на developer.apple.com → News. Проще всего держать Xcode последней версии.
- **Node.js 22 или новее.** Так требует `@capacitor/cli` 8 (`"engines": { "node": ">=22.0.0" }`), на Node 20 команда `npx cap` не запустится. Проверка: `node -v`. Установка: `brew install node@22` или с nodejs.org.
- **Git.** Ставится вместе с Xcode Command Line Tools.
- **Платная подписка Apple Developer Program** (99 $ в год) на ваш Apple ID.
- **iPhone с iOS 15.0 или новее** и кабель — для проверки на устройстве.
- **Интернет** при первом открытии проекта: Xcode скачает пакет `capacitor-swift-pm` 8.5.2 с GitHub.

## 3. Первая настройка

```bash
# 1. Получите репозиторий (адрес — ваш, удалённого репозитория пока нет;
#    можно просто скопировать папку ice-hive на Mac)
git clone <адрес-вашего-репозитория> ice-hive
cd ice-hive

# 2. Зависимости строго по package-lock.json
npm ci

# 3. Сборка www/ и перенос в проект iOS
npm run sync

# 4. Открыть проект в Xcode
npx cap open ios
```

Шаги 3–4 одной командой: `npm run ios`.

`npm run sync` нужен после каждого клонирования и после любых изменений в `game/` или `native/`: папка `ios/App/App/public` с веб-частью не хранится в git.

При первом открытии Xcode в левой панели покажет «Package Dependencies» и начнёт загрузку. Дождитесь, пока исчезнет индикатор «Resolving Package Graph». Если загрузка зависла, смотрите раздел [15](#15-решение-проблем).

## 4. Подпись в Xcode

1. Xcode → **Settings… → Accounts** → «+» → Apple ID. Войдите в аккаунт с подпиской Developer Program.
2. В навигаторе слева выберите проект **App**, затем таргет **App** → вкладка **Signing & Capabilities**.
3. Отметьте **Automatically manage signing**.
4. **Team** — ваша платная команда (не «Personal Team»). Выбирайте для обеих конфигураций, Debug и Release (переключатель «All» вверху вкладки).
5. **Bundle Identifier** должен быть `com.hjj96.icehive`. Xcode сам зарегистрирует App ID на developer.apple.com. Дополнительные возможности (Push, iCloud, Game Center) не нужны.
6. Xcode допишет `DEVELOPMENT_TEAM` в `ios/App/App.xcodeproj/project.pbxproj`. Это ожидаемое изменение, его нужно закоммитить.

Проверьте вкладку **General**:

- **Supported Destinations** — только iPhone;
- **Minimum Deployments** — iOS 15.0;
- **Version** — `1.0.0`, **Build** — `1`;
- **App Icons** — шестиугольная иконка; **Launch Screen File** — `LaunchScreen`;
- **Display Name** — «Ледяной Улей».

Если Xcode предложит «Update to recommended settings», можно согласиться, но потом проверьте, что эти значения не изменились.

## 5. Запуск на iPhone

1. Подключите iPhone кабелем, разблокируйте и нажмите «Доверять этому компьютеру».
2. На iPhone с iOS 16+ включите **Режим разработчика**: «Настройки» → «Конфиденциальность и безопасность» → «Режим разработчика» → вкл, телефон перезагрузится. Пункт появляется после первого подключения к Xcode.
3. В Xcode вверху выберите схему **App** и ваш iPhone в списке устройств.
4. **Product → Run** (⌘R).
5. Если на iPhone появится «Ненадёжный разработчик», откройте «Настройки» → «Основные» → «VPN и управление устройством» → ваш профиль → «Доверять».

Что проверить на устройстве:

- тёмная заставка при запуске, без белой вспышки; заставка держится до первого кадра игры;
- статус-бар скрыт в меню и в игре;
- поворот: портрет и обе альбомные ориентации;
- вибрация при попаданиях и взрывах; в меню паузы есть кнопка «Вибрация: вкл/выкл»;
- настройки (класс, звук, громкость, графика, вибрация) сохраняются после полного закрытия приложения;
- при блокировке экрана, Пункте управления или звонке игра встаёт на паузу, звук останавливается;
- звук: после первого касания; с выключателем «Без звука»; поверх музыки из другого приложения;
- плавность в большой драке; при необходимости «Графика» в меню паузы.

Можно запустить и на симуляторе (например, iPhone 16 Pro Max), но вибрации и реальной производительности там нет.

## 6. Автотесты

На Mac один раз установите браузер для Playwright:

```bash
npx playwright install chromium
```

Затем:

```bash
npm test               # www/: игра загружается, ни одного внешнего запроса, ни одной ошибки
npm run test:native    # мост к iOS в имитации Capacitor: настройки, вибрация, заставка, пауза
npm run test:artifact  # однофайловый артефакт для claude.ai
```

Каждая команда заканчивается строкой `[harness] RESULT PASS` или `FAIL` и при ошибке возвращает код 1. Скриншоты тестов лежат в `harness/out/`.

## 7. Карточка приложения в App Store Connect

1. Откройте [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Apps** (Приложения) → «+» → **New App**.
2. Заполните:
   - **Platforms:** iOS;
   - **Name:** `Ледяной Улей` (если имя занято — запасной вариант в `store/app-store-ru.md`, раздел 1);
   - **Primary Language:** **Russian**;
   - **Bundle ID:** `com.hjj96.icehive` (появится в списке, после того как Xcode зарегистрировал App ID в шаге 4; если его нет — зарегистрируйте на developer.apple.com → Certificates, IDs & Profiles → Identifiers);
   - **SKU:** любой ваш внутренний код, например `icehive-ios-1`;
   - **User Access:** Full Access.
3. **Create**.

Перед публикацией проверьте **Business** (раньше «Agreements, Tax, and Banking»): для бесплатного приложения достаточно принятого соглашения Free Apps. Для платного нужны Paid Apps Agreement, налоговые формы и банковские реквизиты.

## 8. Архив и загрузка сборки

1. Перед каждым архивом выполните `npm run sync`, чтобы в архив попала свежая веб-часть.
2. В Xcode выберите устройство **Any iOS Device (arm64)**.
3. **Product → Archive**. Архив собирается в конфигурации Release. Когда он будет готов, откроется **Organizer**.
4. Рекомендуется: правой кнопкой по архиву → **Generate Privacy Report**. В отчёте должны быть манифест приложения (UserDefaults, причина CA92.1) и манифест Capacitor.
5. **Validate App**. Ошибки подписи и метаданных лучше поймать здесь.
6. **Distribute App** → **App Store Connect** → **Upload**. Оставьте автоматическую подпись и загрузку символов.
7. Через 5–30 минут сборка появится в App Store Connect → TestFlight, и придёт письмо «has completed processing». Вопрос про шифрование не появится: в Info.plist уже стоит `ITSAppUsesNonExemptEncryption = NO`.

Каждая новая загрузка должна иметь больший **Build** (`CURRENT_PROJECT_VERSION`): 1, 2, 3… Повторно загрузить тот же номер нельзя.

## 9. TestFlight: внутреннее тестирование

1. App Store Connect → ваше приложение → **TestFlight**.
2. **Internal Testing** → «+» → создайте группу, например «Команда».
3. Добавьте тестировщиков: это должны быть пользователи вашей команды App Store Connect (Users and Access), в том числе вы сами.
4. Добавьте обработанную сборку в группу.
5. На iPhone установите приложение **TestFlight** из App Store, войдите под тем же Apple ID и установите «Ледяной Улей».

Внутреннее тестирование не требует проверки Apple. Для внешних тестировщиков (по e-mail или публичной ссылке) нужна короткая проверка Beta App Review: заполните «Test Information» и возьмите описание из `store/app-store-ru.md`.

## 10. Заполнение карточки

Все тексты — в **`store/app-store-ru.md`**, у каждого указано число символов. Копируйте содержимое блоков целиком.

**App Information** (общие данные приложения):

- Name, Subtitle — разделы 1–2;
- Category — раздел 6: Games, подкатегории Action и Arcade;
- Content Rights — No (раздел 8);
- **Age Rating** → Edit — ответы из раздела 7. Ожидаемый рейтинг — 13+;
- Privacy Policy URL — см. ниже.

**Политика конфиденциальности (Privacy Policy URL):**

1. Замените в `store/privacy-policy.html` заглушки `[КОНТАКТНЫЙ E-MAIL]`, `[ИМЯ РАЗРАБОТЧИКА]`, `[ДАТА ПУБЛИКАЦИИ]`, `[DATE OF PUBLICATION]`, `[DEVELOPER NAME]`, `[ИМЯ ИЛИ НАЗВАНИЕ ПРАВООБЛАДАТЕЛЯ]`.
2. Опубликуйте страницу по постоянному публичному адресу https. Подойдёт любой статический хостинг: GitHub Pages (отдельный публичный репозиторий с одним `index.html`), Netlify, свой сайт. Страница полностью автономна: без внешних шрифтов и скриптов, сама переключает светлую и тёмную тему.
3. Откройте адрес на телефоне без входа в аккаунты и убедитесь, что страница открывается.
4. Вставьте адрес в App Information → Privacy Policy URL.

**App Privacy** — раздел 8: «No, we do not collect data from this app» → Publish. В карточке появится «Data Not Collected».

**Pricing and Availability:**

- Price — бесплатно или платно, на ваше усмотрение. Встроенных покупок в игре нет.
- Availability — страны. Если российский App Store — основная аудитория, проверьте актуальные ограничения на оплату там: бесплатное приложение распространять проще.
- Для распространения в ЕС App Store Connect попросит указать статус трейдера по Digital Services Act. Без этого ответа приложение не появится в странах ЕС.
- **Apple Silicon Mac Availability:** по умолчанию iPhone-приложение попадает и в Mac App Store на Mac с Apple silicon. Игра под сенсорное управление с вибрацией на macOS не проверялась, поэтому снимите галочку **Make this app available** (Pricing and Availability → Apple Silicon Mac Availability). Если там же есть раздел **Apple Vision Pro**, проверьте его и тоже отключите, если не тестировали игру на Vision Pro. Включить обратно можно в любой момент.

**Страница версии 1.0.0** (iOS App → 1.0 Prepare for Submission):

- **Screenshots:** загрузите все три набора, каждый в свой слот, файлы в порядке номеров (`1-title`, `2-swarm`, `3-beacon`, `4-levelup`, `5-extraction`): `store/screenshots/6.3/` (1206×2622) → iPhone 6.3" Display, `6.9/` (1320×2868) → iPhone 6.9" Display, `6.5/` (1284×2778) → iPhone 6.5" Display. Какой слот обязателен, Apple меняет; смотрите, что App Store Connect помечает как обязательное на странице версии (на момент подготовки — 6.3", iPhone с Dynamic Island среднего размера). Все файлы точно нужного размера, без прозрачности; подробности — `store/app-store-ru.md`, раздел 12.
- iPad-скриншоты не нужны: приложение только для iPhone.
- Promotional Text, Description, Keywords — разделы 3–5. Ключевые слова ограничены 100 **байтами** (кириллица — 2 байта на букву), текущий набор — 99 байт; после правок запустите `npm run check:store`.
- Support URL — обязательно: страница, где игрок найдёт реальные контакты: e-mail и всё, что требует местный закон (часто почтовый адрес и телефон; при распространении в ЕС — те же данные, что вы указали для статуса трейдера по DSA). Можно использовать опубликованную политику конфиденциальности, дополнив её раздел «Контакты». Marketing URL — по желанию.
- Version — `1.0.0`; Copyright — раздел 9 (без знака ©, его добавляет App Store Connect).
- **Build** → «+» → выберите загруженную сборку.
- **App Review Information** — раздел 10: Sign-in required снять; контакты; Notes — текст из блока.
- **Version Release** — вручную (Manually release) или автоматически после одобрения.

Переснять скриншоты после изменения игры — `store/app-store-ru.md`, раздел 12.

## 11. Отправка на проверку

1. На странице версии нажмите **Add for Review**, затем **Submit to App Review**.
2. Статус сменится на «Waiting for Review», потом «In Review». Обычно проверка занимает 1–2 дня.
3. При отказе в **App Review → Messages** будет причина и номер правила. Ответьте там же или исправьте и отправьте снова.
4. После одобрения: при ручном выпуске нажмите **Release This Version**. Приложение появится в App Store в течение нескольких часов.

## 12. Частые причины отказа

| Правило | Что бывает | Как избежать |
|---|---|---|
| 2.1 App Completeness | Вылет, белый экран, заглушки вида `[…]` в ссылках или текстах | Проверить Release-сборку на устройстве через TestFlight; заменить все заглушки в политике и карточке |
| 2.3 Accurate Metadata | Скриншоты не из приложения, обещания того, чего нет | Брать скриншоты из `store/screenshots/`. Не писать «онлайн», «мультиплеер», «кооператив с друзьями»: напарники — ИИ |
| 2.3.10 | Упоминание других платформ (браузер, Android, claude.ai) в карточке | Не упоминать веб-версию в текстах App Store |
| 4.2 Minimum Functionality | «Сайт, обёрнутый в приложение» | Вся игра лежит в приложении и работает офлайн — это сказано в Review Notes; не добавлять загрузку игры с сервера |
| 5.1.1 Privacy | Нет политики, ссылка не открывается, ответы App Privacy не совпадают с поведением | Опубликовать `privacy-policy.html` и проверить ссылку; App Privacy — «Data Not Collected» |
| iPad | iPhone-приложение проверяют и на iPad в режиме совместимости | Запустить на симуляторе iPad: интерфейс должен помещаться и управляться касанием |
| Age Rating | Рейтинг не соответствует содержанию | Ответы из раздела 7 `app-store-ru.md` |
| ITMS-91053 и подобные письма | Не объявлены причины для «required reason API» | Уже сделано в `PrivacyInfo.xcprivacy`. При добавлении новых плагинов проверьте их манифесты |

## 13. Как выпустить обновление

1. Измените игру в `game/head.html` или `game/js/*.js` (мост iOS — `native/bridge.js`). Правило: всё, что касается только iOS, должно ничего не делать, если `window.__native` нет, иначе сломается веб-артефакт.
2. Проверьте:
   ```bash
   npm test && npm run test:native && npm run test:artifact
   ```
3. Соберите и перенесите в Xcode:
   ```bash
   npm run sync
   ```
4. В Xcode → таргет App → **General**:
   - **Version** (`MARKETING_VERSION`) — новая версия для игроков: `1.0.1` для исправлений, `1.1.0` для нового содержимого;
   - **Build** (`CURRENT_PROJECT_VERSION`) — увеличьте на 1 при каждой загрузке.
5. Проверьте на iPhone (раздел 5), затем **Product → Archive** → **Distribute App** (раздел 8).
6. В App Store Connect → iOS App → «+» рядом с версиями → новая версия с тем же номером, что в Xcode. Заполните **What's New**, выберите сборку, **Add for Review**.
7. Если менялся внешний вид, переснимите скриншоты (раздел 12 `app-store-ru.md`) и обновите их на странице версии.
8. Закоммитьте изменения, включая `project.pbxproj` с новыми номерами версии.

Промотекст (Promotional Text) меняется без новой сборки и без проверки.

Иконка: замените `ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` (1024×1024, PNG без прозрачности) и `resources/icon.png`. Новая иконка попадёт в App Store только с новой сборкой.

Перерисовать иконку и заставку из исходников (`resources/src/icon-source.html`, `splash-source.html`): нужны `npm ci`, `npx playwright install chromium` и Pillow для `postprocess.py`:

```bash
python3 -m pip install Pillow
node resources/src/render.mjs --pick hex     # → resources/icon.png, resources/splash.png, resources/src/icon-contact.png
```

Затем скопируйте `resources/icon.png` в `AppIcon-1024.png`, а `resources/splash.png` — в `ios/App/App/Assets.xcassets/Splash.imageset/splash-2732x2732.png`.

## 14. Веб-артефакт

```bash
npm run build:artifact     # → dist/artifact.html
npm run test:artifact      # сборка + тест в обёртке, как у платформы claude.ai
```

`dist/artifact.html` — один файл без `<!doctype>`/`<html>`/`<body>`, начинается с `<title>Ледяной Улей</title>`. three.js подключается через import map с cdn.jsdelivr.net, шрифты — через Google Fonts. Скрипт сам проверяет эти правила и не запишет файл, если они нарушены. Мост iOS в артефакт не входит. Этот файл публикуется как артефакт на claude.ai.

## 15. Решение проблем

**Xcode не может скачать пакеты (Swift Package Manager)**

- Ошибка вида «Missing package product 'Capacitor'» или вечное «Resolving Package Graph»: **File → Packages → Reset Package Caches**, затем **File → Packages → Resolve Package Versions**.
- Нужен доступ к github.com (пакет `ionic-team/capacitor-swift-pm` 8.5.2). Проверьте VPN, прокси и фаервол.
- Плагины подключены из `node_modules` по относительным путям (`ios/App/CapApp-SPM/Package.swift`). Если папки `node_modules` нет, пакеты не найдутся: выполните `npm ci`, затем `npm run sync`.
- Крайний случай: закройте Xcode, удалите `~/Library/Developer/Xcode/DerivedData/App-*` и откройте проект снова.
- Не редактируйте `Package.swift` вручную: его перезаписывает `npx cap sync`.

**Ошибки подписи**

- «No account for team» / «Signing requires a development team» — добавьте Apple ID в Xcode → Settings → Accounts и выберите Team в Signing & Capabilities.
- «Failed to register bundle identifier» / «The app identifier cannot be registered» — идентификатор занят чужой командой. Замените `com.hjj96.icehive` на свой (например, `com.<ваше-имя>.icehive`) в `capacitor.config.json` (`appId`) и в Xcode (Bundle Identifier), затем `npm run sync`.
- «No profiles for 'com.hjj96.icehive' were found» — включите Automatically manage signing; для запуска на телефоне подключите его, Xcode сам добавит устройство.
- «Personal Team» не может загружать в App Store — нужна команда с платной подпиской.

**Белый или чёрный экран при запуске**

1. Возможно, веб-часть не попала в проект: выполните `npm run sync`. Папка `ios/App/App/public` должна содержать `index.html`, `game.js`, `native.js`, `fonts/`.
2. Посмотрите ошибки JavaScript через **Safari Web Inspector**:
   - на iPhone: «Настройки» → «Safari» → «Дополнения» → **Веб-инспектор** — вкл;
   - на Mac: Safari → Настройки → Дополнения → **«Показывать функции для веб-разработчиков»**;
   - запустите приложение из Xcode: Debug-сборка разрешает инспектор (через `CAPACITOR_DEBUG` из `ios/debug.xcconfig`; на устройстве нужна iOS 16.4+). Затем в Safari на Mac: меню **Разработка** → ваш iPhone (или симулятор) → страница приложения → вкладка **Консоль**.
3. Для сравнения прогоните `npm test`: он запускает тот же `www/` в браузере и печатает все ошибки.

**Заставка висит дольше обычного.** Игра сама прячет заставку после первого кадра. Если что-то пошло не так, мост прячет её через 8 секунд. Ищите ошибку в Web Inspector.

**Нет звука.** Звук включается после первого касания экрана (ограничение WebKit). Проверьте «Звук: вкл» и громкость в меню паузы.

**`npx cap` пишет про версию Node.** Нужен Node.js 22+ (`node -v`).

**Тесты пишут, что нет браузера.** Выполните `npx playwright install chromium`.
