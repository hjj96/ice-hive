# Store package

## ICE HIVE 2.0 (English) — current

| File | What |
|---|---|
| `app-store-en.md` | every App Store Connect field with its length, age-rating answers, App Privacy, review notes, what's new |
| `privacy-policy.md`, `privacy-policy.html` | the 2.0 privacy policy (publish the `.html`; fill the `OWNER:` placeholders first) |
| `screenshot-plan-en.md` | the ten landscape shots per size, their staging and captions (shot after the interface overhaul) |

Check before pasting anything into App Store Connect:

```
npm run check:store                # lengths, banned words, facts against ios-native, placeholders listed
npm run check:store -- --release   # the same, and fails while any OWNER: placeholder is left
```

## 1.x (Russian) — deprecated

`app-store-ru.md`, `privacy-policy-ru.md` / `.html` and `screenshots/` are history; see `DEPRECATED-ru.md`.
