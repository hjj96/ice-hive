#!/usr/bin/env python3
"""String-table gate (L10n). No simulator needed.

    check_strings.py                   # source checks (repo)
    check_strings.py --bundle App.app  # also: no Cyrillic in the built bundle, en.lproj compiled

Source checks:
  1. No Cyrillic in Swift string literals of shipped code (App/Sources, IceHiveCore/Sources) outside comments and
     log calls (AppLog / print); none in the app's text resources (Info.plist, JSON, the catalog, …; fonts excepted).
  2. Every TextID (IceHiveCore Text.swift), every UIText (App L10n.swift) and every NameRef key is in
     App/Resources/Localizable.xcstrings with a non-empty English value (plural keys: «one» and «other»); no key in
     the catalog that nothing uses; every key has a context comment.
  3. The catalog's format specifiers match the argument kinds of the id's signature («d» → %lld, «@» → %@;
     positional %n$ or one non-positional run, never mixed; no other specifiers).
  4. Info.plist: development region en, localizations [en], display name «Ice Hive».
Exit 1 on any error; the summary goes to stdout (CI: results/strings.txt).
"""
import json, os, plistlib, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)  # ios-native
CYR = re.compile('[Ѐ-ӿ]')
errors, notes = [], []


def err(msg):
    errors.append(msg)


# ---------------------------------------------------------------- 1. Cyrillic in Swift literals
def swift_literals(text):
    """(line, literal, line text) for every string literal outside comments; handles //, /* */, "…", \"\"\"…\"\"\" and
    #"…"# (escapes are kept; interpolations stay inside the literal)."""
    out, i, n, line = [], 0, len(text), 1
    while i < n:
        c = text[i]
        if c == '\n':
            line += 1; i += 1; continue
        if text.startswith('//', i):
            j = text.find('\n', i); i = n if j < 0 else j; continue
        if text.startswith('/*', i):
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith('/*', i): depth += 1; i += 2
                elif text.startswith('*/', i): depth -= 1; i += 2
                else:
                    if text[i] == '\n': line += 1
                    i += 1
            continue
        hashes = 0
        while c == '#' and i + hashes < n and text[i + hashes] == '#':
            hashes += 1
        if hashes and i + hashes < n and text[i + hashes] == '"':
            i += hashes; c = '"'
        else:
            hashes = 0
        if c == '"':
            multi = text.startswith('"""', i)
            q = '"""' if multi else '"'
            start, j, l0 = i + len(q), i + len(q), line
            close = q + '#' * hashes
            while j < n:
                if text[j] == '\\' and not hashes:
                    j += 2; continue
                if text.startswith(close, j):
                    break
                if text[j] == '\n':
                    line += 1
                    if not multi: break
                j += 1
            lit = text[start:j]
            ls = text.rfind('\n', 0, start) + 1
            le = text.find('\n', start)
            out.append((l0, lit, text[ls:le if le >= 0 else n]))
            i = j + len(close); continue
        i += 1
    return out


LOG_CALL = re.compile(r'AppLog\.(info|error)|\bprint\(|\bfatalError\(|\bassert(ionFailure)?\(|\bprecondition')


def check_swift():
    n = 0
    for base in ('App/Sources', 'IceHiveCore/Sources'):
        for dp, _, fs in os.walk(os.path.join(ROOT, base)):
            for f in sorted(fs):
                if not f.endswith('.swift'):
                    continue
                p = os.path.join(dp, f)
                text = open(p, encoding='utf-8').read()
                for line, lit, src in swift_literals(text):
                    n += 1
                    if CYR.search(lit) and not LOG_CALL.search(src):
                        err('cyrillic literal %s:%d: "%s"' % (os.path.relpath(p, ROOT), line, lit[:60]))
    notes.append('swift literals scanned: %d' % n)


TEXT_EXT = ('.plist', '.json', '.xcstrings', '.strings', '.stringsdict', '.storyboard', '.xcprivacy', '.txt', '.md', '.xml')


def check_resources(base, label):
    n = 0
    for dp, _, fs in os.walk(base):
        for f in sorted(fs):
            p = os.path.join(dp, f)
            if f.endswith(('.ttf', '.otf')):
                continue  # fonts carry Cyrillic glyph names by design
            data = open(p, 'rb').read()
            texts = []
            if f.endswith(('.plist', '.strings', '.stringsdict')) and data[:6] == b'bplist':
                try:
                    texts.append(json.dumps(plistlib.loads(data), ensure_ascii=False, default=str))
                except Exception:
                    texts.append(data.decode('utf-8', 'ignore'))
            elif f.endswith(TEXT_EXT):
                # text: UTF-16 with a byte-order mark (old-style .strings) or UTF-8; anything else is binary (compiled
                # nibs, asset catalogs …) and has no player-facing words of ours
                if data[:2] in (b'\xff\xfe', b'\xfe\xff'):
                    texts.append(data.decode('utf-16', 'ignore'))
                else:
                    try:
                        texts.append(data.decode('utf-8'))
                    except UnicodeDecodeError:
                        continue
            else:
                continue
            n += 1
            for t in texts:
                m = CYR.search(t)
                if m:
                    snippet = re.sub(r'[\x00-\x1f]', ' ', t[max(0, m.start() - 20):m.start() + 20])
                    err('cyrillic in %s %s: …%s…' % (label, os.path.relpath(p, base), snippet))
                    break
    notes.append('%s text files scanned: %d' % (label, n))


# ---------------------------------------------------------------- 2./3. keys and specifiers
def parse_enum(path, enum):
    """{key: signature} of a `enum <name>: String` with `case x = "key"` lines and a `var signature` switch."""
    text = open(path, encoding='utf-8').read()
    m = re.search(r'enum %s: String, CaseIterable \{(.*?)\n    var signature: String \{|enum %s: String, CaseIterable \{(.*?)\n    public var signature: String \{' % (enum, enum), text, re.S)
    if not m:
        err('%s: enum %s not found' % (path, enum)); return {}
    body = m.group(1) or m.group(2)
    cases = dict(re.findall(r'case (\w+) = "([^"]+)"', body))
    sig_start = m.end()
    sig_body = text[sig_start:text.find('\n        }\n    }', sig_start)]
    sig = {}
    for names, s in re.findall(r'case ((?:\.\w+,?\s*)+): return "([d@]*)"', sig_body):
        for nm in re.findall(r'\.(\w+)', names):
            if nm in sig:
                err('%s: %s has two signatures' % (enum, nm))
            sig[nm] = s
    for nm in sig:
        if nm not in cases:
            err('%s: signature for unknown case %s' % (enum, nm))
    return {key: sig.get(nm, '') for nm, key in cases.items()}


def name_keys():
    core = os.path.join(ROOT, 'IceHiveCore/Sources/IceHiveCore')
    tuning = open(os.path.join(core, 'Tuning.swift'), encoding='utf-8').read()
    text = open(os.path.join(core, 'Text.swift'), encoding='utf-8').read()
    profile = open(os.path.join(core, 'Profile.swift'), encoding='utf-8').read()
    classes = re.findall(r'ClassSpec\(id: "(\w+)"', tuning)
    bugs = re.findall(r'BugSpec\(id: "(\w+)"', tuning)
    tiers = re.findall(r'd\.id = "(\w+)"', tuning) + ['v10']
    upg = [u.strip() for u in re.search(r'enum UpgradeID: String, CaseIterable \{\s*case ([^\n]+)', tuning).group(1).split(',')]
    quality = [q.strip() for q in re.search(r'enum QualityTier: String, CaseIterable \{\s*case ([^\n]+)', tuning).group(1).split(',')]
    beacons = re.findall(r'"(\w+)"', re.search(r'beaconKeys = \[([^\]]+)\]', text).group(1))
    ranks = len(re.search(r'thresholds: \[Int\] = \[([^\]]+)\]', profile).group(1).split(','))
    keys = {'name.you': '', 'name.station.kelvin': '', 'name.sector': '@d', 'name.sector.letters': '', 'name.bug.queen': '', 'name.bug.threader': ''}
    for c in classes:
        keys['name.callsign.' + c] = ''
        for part in ('name', 'weapon', 'ability', 'ability_short', 'desc'):
            keys['class.%s.%s' % (c, part)] = ''
    for b in beacons: keys['name.beacon.' + b] = ''
    for b in bugs: keys['name.bug.' + b] = ''
    for t in tiers:
        for part in ('name', 'line', 'abbr'): keys['tier.%s.%s' % (t, part)] = ''
    for r in range(1, ranks + 1): keys['rank.%d' % r] = ''
    for u in upg: keys['upg.%s.name' % u] = ''
    for q in quality: keys['quality.' + q] = ''
    notes.append('names: %d classes, %d bugs, %d tiers, %d upgrades, %d ranks, %d beacons' % (len(classes), len(bugs), len(tiers), len(upg), ranks, len(beacons)))
    return keys


SPEC = re.compile(r'%(?:(\d+)\$)?([-+ #0]*\d*(?:\.\d+)?)(lld|ld|lu|llu|d|i|u|f|g|e|s|@|%|x|X|c)')


def specifiers(value):
    """[(position or None, kind)] of a format string; kind 'd' (%lld) / '@' / 'bad:<spec>'; %% skipped."""
    out = []
    for m in SPEC.finditer(value):
        pos, flags, conv = m.group(1), m.group(2), m.group(3)
        if conv == '%':
            continue
        if flags:
            out.append((pos, 'bad:' + m.group(0)))
        elif conv == 'lld':
            out.append((pos, 'd'))
        elif conv == '@':
            out.append((pos, '@'))
        else:
            out.append((pos, 'bad:' + m.group(0)))
    return out


def check_format(key, value, sig, partial=False):
    sp = specifiers(value)
    for pos, kind in sp:
        if kind.startswith('bad:'):
            err('%s: specifier %s (use %%lld for counts, %%@ for strings)' % (key, kind[4:]))
            return
    positional = [p for p, _ in sp if p]
    if positional and len(positional) != len(sp):
        err('%s: positional and plain specifiers mixed in «%s»' % (key, value)); return
    if positional:
        got = {}
        for p, kind in sp:
            i = int(p) - 1
            if i in got and got[i] != kind:
                err('%s: argument %d used as two kinds' % (key, i + 1))
            got[i] = kind
    else:
        got = {i: kind for i, (_, kind) in enumerate(sp)}
    for i, kind in got.items():
        if i >= len(sig):
            err('%s: argument %d in «%s» but the id has %d (%s)' % (key, i + 1, value, len(sig), sig or 'none')); continue
        if sig[i] != kind:
            err('%s: argument %d is %s in the catalog, %s in code' % (key, i + 1, '%lld' if kind == 'd' else '%@', '%lld' if sig[i] == 'd' else '%@'))
    if not partial:
        for i in range(len(sig)):
            if i not in got:
                err('%s: argument %d (%s) unused in «%s»' % (key, i + 1, sig[i], value))


def check_catalog():
    cat_path = os.path.join(ROOT, 'App/Resources/Localizable.xcstrings')
    if not os.path.exists(cat_path):
        err('no catalog at App/Resources/Localizable.xcstrings'); return
    cat = json.load(open(cat_path, encoding='utf-8'))
    if cat.get('sourceLanguage') != 'en':
        err('catalog sourceLanguage is %r, not en' % cat.get('sourceLanguage'))
    strings = cat.get('strings', {})
    want = {}
    want.update(parse_enum(os.path.join(ROOT, 'IceHiveCore/Sources/IceHiveCore/Text.swift'), 'TextID'))
    n_core = len(want)
    ui = parse_enum(os.path.join(ROOT, 'App/Sources/UI/L10n.swift'), 'UIText')
    for k in ui:
        if k in want: err('key %s is both a TextID and a UIText' % k)
    want.update(ui)
    names = name_keys()
    for k in names:
        if k in want: err('key %s is both a name and a text id' % k)
    want.update(names)
    plural = 0
    for key, sig in sorted(want.items()):
        e = strings.get(key)
        if e is None:
            err('missing in the catalog: %s' % key); continue
        if not (e.get('comment') or '').strip():
            err('%s: no context comment' % key)
        en = (e.get('localizations') or {}).get('en') or {}
        unit = (en.get('stringUnit') or {}).get('value')
        var = ((en.get('variations') or {}).get('plural')) or {}
        if var:
            plural += 1
            if sig.count('d') < 1:
                err('%s: plural variants but no count argument' % key)
            for form in ('one', 'other'):
                v = ((var.get(form) or {}).get('stringUnit') or {}).get('value')
                if not (v or '').strip():
                    err('%s: plural form «%s» empty' % (key, form))
                else:
                    check_format(key + '[' + form + ']', v, sig, partial=(form == 'one'))
        elif unit is None or not unit.strip():
            err('%s: no English value' % key)
        else:
            check_format(key, unit, sig)
        if key == 'name.sector.letters' and unit and len(unit) != 12:
            err('name.sector.letters must have 12 letters, has %d' % len(unit))
    for key in sorted(set(strings) - set(want)):
        err('catalog key nothing uses: %s' % key)
    notes.append('catalog: %d keys (%d core texts, %d app texts, %d names), %d with plural variants' % (len(strings), n_core, len(ui), len(names), plural))


def check_plist():
    p = plistlib.load(open(os.path.join(ROOT, 'App/Resources/Info.plist'), 'rb'))
    if p.get('CFBundleDevelopmentRegion') != 'en': err('Info.plist CFBundleDevelopmentRegion %r' % p.get('CFBundleDevelopmentRegion'))
    if p.get('CFBundleLocalizations') != ['en']: err('Info.plist CFBundleLocalizations %r' % p.get('CFBundleLocalizations'))
    if p.get('CFBundleDisplayName') != 'Ice Hive': err('Info.plist CFBundleDisplayName %r' % p.get('CFBundleDisplayName'))


def check_bundle(app):
    for f in ('en.lproj/Localizable.strings', 'en.lproj/Localizable.stringsdict'):
        if not os.path.exists(os.path.join(app, f)):
            err('bundle: no %s' % f)
    if os.path.exists(os.path.join(app, 'Localizable.xcstrings')):
        err('bundle: the catalog was copied, not compiled (Localizable.xcstrings in the app)')
    for d in os.listdir(app):
        if d.endswith('.lproj') and d not in ('en.lproj', 'Base.lproj'):
            err('bundle: unexpected localization %s' % d)
    check_resources(app, 'bundle')


def main():
    args = sys.argv[1:]
    check_swift()
    check_resources(os.path.join(ROOT, 'App/Resources'), 'resources')
    check_catalog()
    check_plist()
    if '--bundle' in args:
        check_bundle(args[args.index('--bundle') + 1])
    for n in notes:
        print('note  ' + n)
    for e in errors:
        print('ERROR ' + e)
    print('strings: %s (%d errors)' % ('ok' if not errors else 'FAIL', len(errors)))
    sys.exit(1 if errors else 0)


if __name__ == '__main__':
    main()
