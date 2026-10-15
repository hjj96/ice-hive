// «Ледяной Улей» — the three app-icon concepts as SVG markup for a 1024x1024 viewBox.
// Used by icon-source.html (the icon) and splash-source.html (the emblem on the launch screen).
// Needs bug.js loaded first.
(function () {
  const C = { bg: '#05070a', bg2: '#0a0f15', teal: '#3fe3d2', amber: '#ffb420', ink: '#dbe6ee',
              red: '#ff3b3b', pyro: '#ffb42a', cryo: '#4cc9ff', gunner: '#62ff70', pink: '#ff3f7f' };

  // deterministic PRNG (mulberry32) so re-renders are identical
  function rng(seed) { return function () { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
  const P = (pts) => pts.map((p) => p[0].toFixed(1) + ',' + p[1].toFixed(1)).join(' ');
  const hexPts = (cx, cy, r) => Array.from({ length: 6 }, (_, k) => { const a = (-90 + 60 * k) * Math.PI / 180; return [cx + r * Math.cos(a), cy + r * Math.sin(a)]; });
  const mix = (a, b, t) => { const pa = [1, 3, 5].map((i) => parseInt(a.slice(i, i + 2), 16)), pb = [1, 3, 5].map((i) => parseInt(b.slice(i, i + 2), 16)); return 'rgb(' + pa.map((v, i) => Math.round(v + (pb[i] - v) * t)).join(',') + ')'; };

  // grating: rows of rounded slots, like the station catwalks
  function grating(id, metal, slot, rot) {
    return `<pattern id="${id}" width="72" height="36" patternUnits="userSpaceOnUse" patternTransform="rotate(${rot})">
      <rect width="72" height="36" fill="${metal}"/>
      <rect x="6" y="7" width="48" height="9" rx="4.5" fill="${slot}"/>
      <rect x="42" y="25" width="48" height="9" rx="4.5" fill="${slot}"/>
      <rect x="-30" y="25" width="48" height="9" rx="4.5" fill="${slot}"/>
      <rect x="0" y="0" width="72" height="1.5" fill="${slot}" opacity=".5"/>
    </pattern>`;
  }

  // ==========================================================================================
  // Concept «Сота» (hive cell) — the game's name as one mark: a faceted ICE hexagon (ледяной)
  // that is a HIVE cell (улей); the swarm bug, backlit in cold teal, claws hooked over the rim,
  // breaking out through the top. Ice cracks where the claws bite.
  // ==========================================================================================
  function hex(opt) {
    opt = opt || {};
    const cx = 512, cy = 522, Ro = 422, Ri = 338;
    const O = hexPts(cx, cy, Ro), I = hexPts(cx, cy, Ri);
    const bug = { x: 512, y: 466, s: 0.9 };
    const r = rng(11);
    // facets lit from the top-left (light falls on the up-left faces, the down-right ones sit in shadow)
    const L = [-0.55, -0.83];
    let faces = '';
    for (let k = 0; k < 6; k++) {
      const a = (-60 + 60 * k) * Math.PI / 180;
      const t = (Math.cos(a) * L[0] + Math.sin(a) * L[1] + 1) / 2;
      const c0 = t < 0.5 ? mix('#06272b', '#23a597', t / 0.5) : mix('#23a597', '#eafffc', (t - 0.5) / 0.5);
      const c1 = t < 0.5 ? mix('#031417', '#127a70', t / 0.5) : mix('#127a70', '#9ff2e8', (t - 0.5) / 0.5);
      // gradient across the facet: outer edge brighter, inner edge deeper (bevelled ice)
      const mo = [(O[k][0] + O[(k + 1) % 6][0]) / 2, (O[k][1] + O[(k + 1) % 6][1]) / 2];
      const mi = [(I[k][0] + I[(k + 1) % 6][0]) / 2, (I[k][1] + I[(k + 1) % 6][1]) / 2];
      faces += `<linearGradient id="fg${k}" gradientUnits="userSpaceOnUse" x1="${mo[0]}" y1="${mo[1]}" x2="${mi[0]}" y2="${mi[1]}"><stop offset="0" stop-color="${c0}"/><stop offset="1" stop-color="${c1}"/></linearGradient>`;
      faces += `<polygon points="${P([O[k], O[(k + 1) % 6], I[(k + 1) % 6], I[k]])}" fill="url(#fg${k})"/>`;
    }
    // facet seams (bevel edges at the corners)
    let seams = '';
    for (let k = 0; k < 6; k++) seams += `<line x1="${O[k][0]}" y1="${O[k][1]}" x2="${I[k][0]}" y2="${I[k][1]}" stroke="#ffffff" stroke-width="3" opacity="${k === 0 || k === 5 || k === 4 ? .75 : .25}"/>`;

    // cracks: jagged radial fractures where each claw bites the ice (clipped to the rim)
    function crack(x, y, ang, len, w, depth) {
      let pts = [[x, y]], a = ang, out = '';
      const n = 4;
      for (let i = 0; i < n; i++) {
        a += (r() - .5) * 0.7; const st = len / n; x += Math.cos(a) * st; y += Math.sin(a) * st; pts.push([x, y]);
        if (depth > 0 && i === 1 && r() > .3) out += crack(x, y, a + (r() > .5 ? .8 : -.8), len * .5, w * .65, depth - 1);
      }
      return `<polyline points="${P(pts)}" fill="none" stroke="#03191c" stroke-width="${(w + 2).toFixed(1)}" stroke-linejoin="bevel" opacity=".5" transform="translate(1.5,2)"/>` +
             `<polyline points="${P(pts)}" fill="none" stroke="#f4ffff" stroke-width="${w.toFixed(1)}" stroke-linejoin="bevel" opacity=".95"/>` + out;
    }
    let cracks = '';
    const tips = [];
    for (const t of BUG.TIPS.slice(0, 3)) { tips.push([bug.x + t[0] * bug.s, bug.y + t[1] * bug.s]); tips.push([bug.x - t[0] * bug.s, bug.y + t[1] * bug.s]); }
    for (const t of tips) {
      const ang = Math.atan2(t[1] - cy, t[0] - cx);
      // fractures run along the facet, away from the claw
      for (let j = 0; j < 3; j++) cracks += crack(t[0], t[1], ang + Math.PI / 2 * (j === 0 ? 1 : -1) + (j === 2 ? -0.9 : 0) + (r() - .5) * .5, 46 + r() * 40, 2.2, 1);
    }
    // breach at the top vertex: the mandibles punched through
    const top = [cx, cy - (Ro + Ri) / 2];
    for (let j = 0; j < 6; j++) cracks += crack(top[0] + (j - 2.5) * 16, top[1] + 12, (j < 3 ? Math.PI * 0.86 : Math.PI * 0.14) + (r() - .5) * .4, 80 + r() * 60, 3 - Math.abs(j - 2.5) * .4, 1);
    const breach = [[cx - 74, cy - Ro - 4], [cx - 52, cy - Ro + 30], [cx - 66, cy - Ri + 6], [cx - 30, cy - Ri - 22], [cx - 12, cy - Ri + 4], [cx + 16, cy - Ri - 26], [cx + 44, cy - Ri + 2], [cx + 62, cy - Ro + 34], [cx + 80, cy - Ro - 6]];
    let shards = '';
    // ice chunks knocked out of the breach: two-tone (lit face + shadow face) so they read as solid ice
    const sh = [[-104, -446, 30, 28], [100, -452, 26, -34], [-34, -482, 16, 50], [46, -490, 13, -70]];
    for (const s of sh) {
      const k = s[2];
      shards += `<g transform="translate(${cx + s[0]},${cy + s[1]}) rotate(${s[3]})">` +
        `<polygon points="0,${-k} ${k * .7},${-k * .1} ${k * .25},${k * .7} ${-k * .6},${k * .35}" fill="#127a70"/>` +
        `<polygon points="0,${-k} ${k * .7},${-k * .1} ${k * .05},${k * .1} ${-k * .6},${k * .35}" fill="#eafffc"/></g>`;
    }

    // honeycomb behind the bug
    let comb = '';
    const hr = 36, hw = hr * Math.sqrt(3);
    for (let row = -9; row <= 9; row++) for (let col = -7; col <= 7; col++) {
      const x = cx + col * hw + (row & 1 ? hw / 2 : 0), y = cy + row * hr * 1.5;
      comb += `<polygon points="${P(hexPts(x, y, hr - 3.5))}"/>`;
    }
    let dust = '';
    for (let i = 0; i < 44; i++) {
      const a = r() * Math.PI * 2, d = Ro + 30 + r() * 150, x = cx + Math.cos(a) * d, y = cy + Math.sin(a) * d;
      if (x < 40 || y < 40 || x > 984 || y > 984) continue;
      dust += `<circle cx="${x.toFixed(0)}" cy="${y.toFixed(0)}" r="${(1.4 + r() * 2.8).toFixed(1)}" fill="#cfefff" opacity="${(.12 + r() * .4).toFixed(2)}"/>`;
    }
    const rimD = `M${P(O).replace(/ /g, 'L')}Z M${P(I).replace(/ /g, 'L')}Z`;
    const bugT = `translate(${bug.x},${bug.y}) scale(${bug.s})`;
    return `
<defs>
  <radialGradient id="bgG" cx="512" cy="520" r="740" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#0f272b"/><stop offset=".5" stop-color="${C.bg2}"/><stop offset="1" stop-color="${C.bg}"/></radialGradient>
  <radialGradient id="glowG" cx="512" cy="600" r="380" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#c8fff8"/><stop offset=".22" stop-color="${C.teal}"/><stop offset=".68" stop-color="#0e625c"/><stop offset="1" stop-color="#05201f"/></radialGradient>
  <clipPath id="inC"><polygon points="${P(I)}"/></clipPath>
  <clipPath id="rimC"><path d="${rimD}" clip-rule="evenodd"/></clipPath>
  <mask id="breachM" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><rect width="1024" height="1024" fill="#fff"/><polygon points="${P(breach)}" fill="#000"/></mask>
  <filter id="blur10" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="10"/></filter>
  <filter id="blur36" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="36"/></filter>
  <filter id="frost" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="0.03" numOctaves="5" seed="9"/><feColorMatrix type="matrix" values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  2.4 0 0 0 -1.15"/></filter>
  <filter id="grain" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="0.7" numOctaves="2" seed="4"/><feColorMatrix type="matrix" values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  3 0 0 0 -1.9"/></filter>
  <radialGradient id="vig" cx="512" cy="512" r="760" gradientUnits="userSpaceOnUse"><stop offset=".55" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".7"/></radialGradient>
  ${faces.match(/<linearGradient[\s\S]*?<\/linearGradient>/g).join('')}
</defs>
${opt.bare ? '' : `<rect width="1024" height="1024" fill="url(#bgG)"/>${dust}`}
<polygon points="${P(O)}" fill="${C.teal}" opacity=".32" filter="url(#blur36)"/>
<!-- cell interior: teal backlight + honeycomb -->
<polygon points="${P(I)}" fill="url(#glowG)"/>
<g clip-path="url(#inC)" fill="none" stroke="#031618" stroke-width="6" opacity=".38">${comb}</g>
<!-- ice rim -->
<g mask="url(#breachM)">
  ${faces.replace(/<linearGradient[\s\S]*?<\/linearGradient>/g, '')}
  <g clip-path="url(#rimC)">
    <rect width="1024" height="1024" filter="url(#frost)" opacity=".22"/>
    <rect width="1024" height="1024" filter="url(#grain)" opacity=".35"/>
  </g>
  ${seams}
  <polygon points="${P(I)}" fill="none" stroke="#eafffd" stroke-width="5" opacity=".8"/>
  <polygon points="${P(O)}" fill="none" stroke="#011012" stroke-width="7" opacity=".85"/>
  <g clip-path="url(#rimC)">${cracks}</g>
</g>
<polygon points="${P(breach)}" fill="none" stroke="#f4ffff" stroke-width="4" stroke-linejoin="bevel" opacity=".9" clip-path="url(#rimC)"/>
${shards}
<!-- bug: dark against the backlight, cold rim along every edge -->
<g filter="url(#blur10)" opacity=".85"><path d="${BUG.SIL_D}" fill="#000" transform="translate(${bug.x},${bug.y + 16}) scale(${bug.s})"/></g>
<g transform="${bugT}">${BUG.detailed('b2', { base: '#040306', plate: '#170f1a', sheen: '#8ff0e6', sheenOpacity: .26, edge: '#9ff8ee', edgeW: 3.5, edgeOpacity: .85 })}</g>
${opt.bare ? '' : '<rect width="1024" height="1024" fill="url(#vig)"/>'}`;
  }

  // ==========================================================================================
  // Concept «Луч» (beam) — a flashlight cone cuts the dark station floor; one swarm bug caught in the
  // pool of light with a red laser sight on its head, more of the swarm at the edge of the light.
  // ==========================================================================================
  function beam() {
    const S = [-40, 1064];
    const bug = { x: 614, y: 420, r: 225, s: 0.86 };
    const hit = [528, 506];
    const r = rng(7);
    let snow = '';
    for (let i = 0; i < 46; i++) {
      const t = 120 + r() * 820, u = (r() - 0.5) * (0.2 + t / 900) * 520;
      const x = S[0] + t * 0.7071 + u * 0.7071, y = S[1] - t * 0.7071 + u * 0.7071;
      const rad = 1.6 + r() * 4.2, op = 0.35 + r() * 0.55;
      snow += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${rad.toFixed(1)}" fill="#f4fbff" opacity="${op.toFixed(2)}"${rad > 4.4 ? ' filter="url(#soft)"' : ''}/>`;
    }
    // the rest of the swarm: dark shapes creeping in at the rim of the light
    let swarm = '';
    const far = [[268, 238, 160, .3], [182, 470, 120, .26], [800, 740, 290, .28], [930, 300, 250, .22], [440, 110, 200, .22]];
    for (const b of far) swarm += `<g transform="translate(${b[0]},${b[1]}) rotate(${b[2]}) scale(${b[3]})"><path d="${BUG.SIL_D}" fill="#060509"/><circle cx="-24" cy="-158" r="17" fill="${C.red}"/><circle cx="24" cy="-158" r="17" fill="${C.red}"/></g>`;
    let pinks = '';
    for (let i = 0; i < 40; i++) {
      const x = 60 + r() * 900, y = 60 + r() * 900;
      if (x + y > 760 && x + y < 1400 && Math.abs(x - y - 140) < 520) continue; // keep out of the beam
      pinks += `<circle cx="${x.toFixed(0)}" cy="${y.toFixed(0)}" r="${(2 + r() * 3).toFixed(1)}" fill="${r() > .4 ? C.pink : C.red}" opacity="${(.45 + r() * .5).toFixed(2)}"/>`;
    }
    const bugT = `translate(${bug.x},${bug.y}) rotate(${bug.r}) scale(${bug.s})`;
    return `
<defs>
  <radialGradient id="bgG" cx="640" cy="380" r="760" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#0d151e"/><stop offset=".6" stop-color="${C.bg2}"/><stop offset="1" stop-color="${C.bg}"/></radialGradient>
  ${grating('gDark', '#0b1118', '#05080c', -45)}
  ${grating('gLit', '#dfe8ee', '#5f6c78', -45)}
  <pattern id="haz" width="34" height="34" patternUnits="userSpaceOnUse"><rect width="34" height="34" fill="#141414"/><rect width="17" height="34" fill="${C.amber}"/></pattern>
  <linearGradient id="beamG" x1="${S[0]}" y1="${S[1]}" x2="${S[0] + 900 * .7071}" y2="${S[1] - 900 * .7071}" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset=".55" stop-color="#fff" stop-opacity=".6"/><stop offset=".85" stop-color="#fff" stop-opacity=".95"/><stop offset="1" stop-color="#fff" stop-opacity=".9"/></linearGradient>
  <radialGradient id="poolG"><stop offset="0" stop-color="#fff"/><stop offset=".72" stop-color="#fff" stop-opacity=".96"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
  <filter id="feather" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="9"/></filter>
  <filter id="soft"><feGaussianBlur stdDeviation="2.2"/></filter>
  <filter id="blur6" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="6"/></filter>
  <filter id="blur14" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="14"/></filter>
  <mask id="lightM" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
    <rect width="1024" height="1024" fill="#000"/>
    <g filter="url(#feather)">
      <polygon points="${P([S, [794, 630], [394, 230]])}" fill="url(#beamG)"/>
      <ellipse cx="0" cy="0" rx="340" ry="262" fill="url(#poolG)" transform="translate(590,440) rotate(-45)"/>
    </g>
  </mask>
  <clipPath id="floorC"><polygon points="0,0 1024,0 1024,246 246,1024 0,1024"/></clipPath>
  <radialGradient id="vig" cx="512" cy="512" r="760" gradientUnits="userSpaceOnUse"><stop offset=".5" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".75"/></radialGradient>
  <linearGradient id="abyss" x1="1024" y1="1024" x2="600" y2="600" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#020305"/><stop offset="1" stop-color="#0a1219"/></linearGradient>
</defs>
<rect width="1024" height="1024" fill="url(#bgG)"/>
<polygon points="1024,246 1024,1024 246,1024" fill="url(#abyss)"/>
<g clip-path="url(#floorC)"><rect width="1024" height="1024" fill="url(#gDark)"/></g>
${pinks}
<g mask="url(#lightM)">
  <g clip-path="url(#floorC)">
    <rect width="1024" height="1024" fill="url(#gLit)"/>
    <rect width="1024" height="1024" fill="#eaf6ff" opacity=".22"/>
  </g>
  <polygon points="1024,246 1024,1024 246,1024" fill="#7f97aa" opacity=".22"/>
</g>
<g mask="url(#lightM)"><polygon points="${P([[1024, 206], [1024, 246], [246, 1024], [206, 1024]])}" fill="url(#haz)"/></g>
<polygon points="${P([[1024, 206], [1024, 246], [246, 1024], [206, 1024]])}" fill="url(#haz)" opacity=".16"/>
<line x1="1024" y1="246" x2="246" y2="1024" stroke="#000" stroke-width="5" opacity=".7"/>
${swarm}
<g transform="translate(30,-30)" opacity=".8" filter="url(#blur6)"><path d="${BUG.SIL_D}" fill="#000" transform="${bugT}"/></g>
<g transform="translate(-5,6)"><path d="${BUG.SIL_D}" fill="#cfe7f5" transform="${bugT}"/></g>
<g transform="${bugT}">${BUG.detailed('b1', { base: '#0d0a11', plate: '#3a2538', sheen: '#b6c9d8', sheenOpacity: .5 })}</g>
<g mask="url(#lightM)">${snow}</g>
<line x1="40" y1="1110" x2="${hit[0]}" y2="${hit[1]}" stroke="${C.red}" stroke-width="26" opacity=".35" filter="url(#blur6)"/>
<line x1="40" y1="1110" x2="${hit[0]}" y2="${hit[1]}" stroke="#ff2a2a" stroke-width="9"/>
<line x1="40" y1="1110" x2="${hit[0]}" y2="${hit[1]}" stroke="#ffe3e0" stroke-width="3"/>
<circle cx="${hit[0]}" cy="${hit[1]}" r="38" fill="${C.red}" opacity=".7" filter="url(#blur14)"/>
<circle cx="${hit[0]}" cy="${hit[1]}" r="13" fill="#ff5a4a"/>
<circle cx="${hit[0]}" cy="${hit[1]}" r="6" fill="#fff"/>
<rect width="1024" height="1024" fill="url(#vig)"/>`;
  }

  // ==========================================================================================
  // Concept «Перекрестье» (crossfire) — the squad's four laser sights (red / amber / cyan / green)
  // fan up from the bottom and converge on a charging bug inside a beacon's amber hazard ring.
  // ==========================================================================================
  function lasers() {
    const cx = 512, cy = 512;
    const bug = { x: cx, y: 448, s: 0.6 };
    const hit = [cx, bug.y + 150 * bug.s];
    const src = [[120, 1100, C.red], [400, 1120, C.pyro], [624, 1120, C.cryo], [904, 1100, C.gunner]];
    let beams = '';
    for (const s of src) {
      beams += `<line x1="${s[0]}" y1="${s[1]}" x2="${hit[0]}" y2="${hit[1]}" stroke="${s[2]}" stroke-width="30" opacity=".35" filter="url(#blur8)"/>`;
      beams += `<line x1="${s[0]}" y1="${s[1]}" x2="${hit[0]}" y2="${hit[1]}" stroke="${s[2]}" stroke-width="10"/>`;
      beams += `<line x1="${s[0]}" y1="${s[1]}" x2="${hit[0]}" y2="${hit[1]}" stroke="#fff" stroke-width="3" opacity=".85"/>`;
    }
    const r = rng(5);
    let snow = '';
    for (let i = 0; i < 60; i++) snow += `<circle cx="${(r() * 1024).toFixed(0)}" cy="${(r() * 1024).toFixed(0)}" r="${(1.2 + r() * 3).toFixed(1)}" fill="#dfeffa" opacity="${(.15 + r() * .5).toFixed(2)}"/>`;
    const bugT = `translate(${bug.x},${bug.y}) rotate(180) scale(${bug.s})`;
    return `
<defs>
  <radialGradient id="bgG" cx="512" cy="470" r="620" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#3a4b59"/><stop offset=".42" stop-color="#16212b"/><stop offset="1" stop-color="${C.bg}"/></radialGradient>
  ${grating('gr', '#000', '#000', -45)}
  <pattern id="haz" width="44" height="44" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="44" height="44" fill="#0a0c0f"/><rect width="22" height="44" fill="${C.amber}"/></pattern>
  <filter id="blur8" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="8"/></filter>
  <filter id="blur20" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="20"/></filter>
  <radialGradient id="vig" cx="512" cy="512" r="740" gradientUnits="userSpaceOnUse"><stop offset=".5" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".8"/></radialGradient>
</defs>
<rect width="1024" height="1024" fill="url(#bgG)"/>
<rect width="1024" height="1024" fill="url(#gr)" opacity=".3"/>
<circle cx="${cx}" cy="${cy}" r="370" fill="none" stroke="${C.amber}" stroke-width="80" opacity=".22" filter="url(#blur20)"/>
<circle cx="${cx}" cy="${cy}" r="370" fill="none" stroke="url(#haz)" stroke-width="60"/>
<circle cx="${cx}" cy="${cy}" r="340" fill="none" stroke="#0a0c0f" stroke-width="6"/>
<circle cx="${cx}" cy="${cy}" r="400" fill="none" stroke="#0a0c0f" stroke-width="6"/>
${snow}
<g transform="translate(14,22)" filter="url(#blur8)" opacity=".85"><path d="${BUG.SIL_D}" fill="#000" transform="${bugT}"/></g>
<g transform="${bugT}">${BUG.detailed('b3', { base: '#0b0910', plate: '#3a2538', sheen: '#a9bdcc', sheenOpacity: .45, edge: '#b9d6e8', edgeW: 4, edgeOpacity: .7 })}</g>
${beams}
<circle cx="${hit[0]}" cy="${hit[1]}" r="50" fill="#fff" opacity=".55" filter="url(#blur20)"/>
<circle cx="${hit[0]}" cy="${hit[1]}" r="15" fill="#fff"/>
<rect width="1024" height="1024" fill="url(#vig)"/>`;
  }

  window.ICON = { hex, beam, lasers };
})();
