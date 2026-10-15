// «Ледяной Улей» — shared emblem geometry (icon + splash).
// The swarm bug, seen top-down, head pointing to -y. Local units: thorax centre = (0,0);
// the body spans y -348 (mandible tips) .. +400 (tail stinger), legs reach x ±396.
// Plain SVG markup built from strings: no dependencies, deterministic output.
(function () {
  const f = (p) => p[0].toFixed(1) + ',' + p[1].toFixed(1);

  // Catmull-Rom through points -> cubic Bezier path. Points flagged 's' become sharp corners.
  function smooth(pts, closed) {
    const n = pts.length;
    const get = (i) => (closed ? pts[(i + n) % n] : pts[Math.max(0, Math.min(n - 1, i))]);
    let d = 'M' + f(pts[0]);
    const segs = closed ? n : n - 1;
    const t = 1 / 6;
    for (let i = 0; i < segs; i++) {
      const p0 = get(i - 1), p1 = get(i), p2 = get(i + 1), p3 = get(i + 2);
      const c1 = p1[2] === 's' ? p1 : [p1[0] + (p2[0] - p0[0]) * t, p1[1] + (p2[1] - p0[1]) * t];
      const c2 = p2[2] === 's' ? p2 : [p2[0] - (p3[0] - p1[0]) * t, p2[1] - (p3[1] - p1[1]) * t];
      d += 'C' + f(c1) + ' ' + f(c2) + ' ' + f(p2);
    }
    return d + (closed ? 'Z' : '');
  }

  // Dense samples along a Catmull-Rom spline (open) with linearly interpolated widths.
  function sampleSmooth(pts, ws, per) {
    const out = [], n = pts.length;
    const get = (i) => pts[Math.max(0, Math.min(n - 1, i))];
    for (let i = 0; i < n - 1; i++) {
      const p0 = get(i - 1), p1 = get(i), p2 = get(i + 1), p3 = get(i + 2);
      for (let k = 0; k < per; k++) {
        const t = k / per, t2 = t * t, t3 = t2 * t;
        const c = (j) => 0.5 * (2 * p1[j] + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2 + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3);
        out.push([c(0), c(1), ws[i] + (ws[i + 1] - ws[i]) * t]);
      }
    }
    out.push([pts[n - 1][0], pts[n - 1][1], ws[n - 1]]);
    return out;
  }

  // Tapered limb polygon. angular=true keeps sharp knees (mitred joints), else a smooth curve.
  function limb(pts, ws, angular) {
    const s = angular ? pts.map((p, i) => [p[0], p[1], ws[i]]) : sampleSmooth(pts, ws, 8);
    const L = [], R = [];
    for (let i = 0; i < s.length; i++) {
      const nrm = (a, b) => { const dx = b[0] - a[0], dy = b[1] - a[1], l = Math.hypot(dx, dy) || 1; return [-dy / l, dx / l]; };
      const nIn = i > 0 ? nrm(s[i - 1], s[i]) : null, nOut = i < s.length - 1 ? nrm(s[i], s[i + 1]) : null;
      let n = nIn && nOut ? [nIn[0] + nOut[0], nIn[1] + nOut[1]] : (nIn || nOut);
      const l = Math.hypot(n[0], n[1]) || 1; n = [n[0] / l, n[1] / l];
      const ref = nIn || nOut;
      const miter = Math.min(2.2, 1 / Math.max(0.3, n[0] * ref[0] + n[1] * ref[1]));
      const w = (s[i][2] / 2) * (angular ? miter : 1);
      L.push([s[i][0] + n[0] * w, s[i][1] + n[1] * w]);
      R.push([s[i][0] - n[0] * w, s[i][1] - n[1] * w]);
    }
    return 'M' + L.map(f).join('L') + 'L' + R.reverse().map(f).join('L') + 'Z';
  }

  const mirror = (pts) => pts.map((p) => [-p[0], p[1], p[2]]);

  // ---- body outline (right half, head notch -> tail stinger) ----
  // Compact armoured thorax, big sickle mandibles, a short pointed abdomen of 4 overlapping
  // serrated plates, long bladed legs: an alien warrior bug, not a household insect.
  const SEAMS = [[124, 108], [126, 178], [106, 248], [70, 306]]; // [half-width at notch, y]
  const RIGHT = [
    [0, -168, 's'], [26, -190], [60, -186], [84, -164], [104, -146, 's'], [80, -122], [50, -96, 's'], // head + cheek horn
    [92, -90], [150, -122, 's'], [114, -64], [122, -24], [146, -6, 's'], [100, 22], [52, 46, 's'], // thorax: shoulder horn, side blade
    [104, 62], [158, 104, 's'], [122, 108, 's'],
    [142, 140], [166, 182, 's'], [124, 178, 's'],
    [130, 212], [140, 258, 's'], [104, 248, 's'],
    [100, 276], [100, 318, 's'], [68, 306, 's'],
    [46, 340], [0, 404, 's'],
  ];
  const BODY = RIGHT.concat(mirror(RIGHT.slice(1, -1)).reverse());

  // ---- limbs (right side; mirrored for the left). a = angular joints ----
  const LIMBS = [
    // mandible: sickle hooking inward + inner teeth
    { p: [[24, -180], [70, -226], [88, -280], [68, -326], [18, -348]], w: [50, 40, 28, 14, 0] },
    { p: [[82, -256], [52, -262]], w: [18, 0], a: 1 },
    { p: [[78, -304], [52, -304]], w: [13, 0], a: 1 },
    // front leg (scythe) + barbs
    { p: [[84, -74], [196, -150], [238, -250], [222, -360]], w: [50, 32, 20, 0], a: 1 },
    { p: [[194, -146], [242, -140]], w: [18, 0], a: 1 },
    { p: [[230, -290], [258, -280]], w: [12, 0], a: 1 },
    // middle leg + barbs
    { p: [[108, -22], [234, -58], [334, -10], [396, 88]], w: [52, 32, 20, 0], a: 1 },
    { p: [[232, -54], [252, -104]], w: [18, 0], a: 1 },
    { p: [[362, 30], [394, 18]], w: [12, 0], a: 1 },
    // rear leg + barbs
    { p: [[96, 24], [198, 94], [254, 200], [322, 306]], w: [50, 32, 20, 0], a: 1 },
    { p: [[196, 90], [244, 76]], w: [18, 0], a: 1 },
    { p: [[284, 246], [318, 232]], w: [12, 0], a: 1 },
  ];

  let LIMBS_D = '';
  for (const l of LIMBS) LIMBS_D += limb(l.p, l.w, l.a) + limb(mirror(l.p), l.w, l.a);
  const BODY_D = smooth(BODY, true);
  const SIL_D = BODY_D + LIMBS_D;
  const TIPS = [[222, -360], [396, 88], [322, 306], [18, -348]]; // right-side leg/mandible tips

  // Shaded bug: chitin plates, overlapping abdominal tergites, glowing pink pores + red eyes.
  // id must be unique per document. o.edge = colour of a backlit inner edge glow (or null).
  function detailed(id, o) {
    o = Object.assign({ base: '#0e0a12', plate: '#2a1a2c', seam: '#000', sheen: '#6f5a7a', glint: '#ff3f7f', eye: '#ff2a3a',
      glints: true, sheenOpacity: 0.55, edge: null, edgeW: 16, edgeOpacity: 0.9, poreScale: 1 }, o || {});
    let seams = '';
    for (const [w0, y] of SEAMS) {
      const w = w0 - 2;
      seams += `<path d="M${-w},${y} Q0,${y + 34} ${w},${y}" fill="none" stroke="${o.seam}" stroke-width="10" opacity=".85"/>`;
      seams += `<path d="M${-w + 8},${y - 9} Q0,${y + 24} ${w - 8},${y - 9}" fill="none" stroke="${o.sheen}" stroke-width="3.5" opacity=".55"/>`;
    }
    const pores = [[-96, 140, 6], [98, 146, 6], [-92, 212, 6], [94, 206, 5], [-66, 276, 5], [68, 272, 5], [-20, 330, 4], [16, 180, 4],
      [-90, -30, 5], [92, -24, 5], [0, 372, 5]];
    const eyes = [[-26, -162, 11], [26, -162, 11], [-54, -146, 7.5], [54, -146, 7.5]];
    let glints = '';
    if (o.glints) {
      const k = o.poreScale;
      glints += `<g filter="url(#${id}-glow)">` + pores.map((p) => `<circle cx="${p[0]}" cy="${p[1]}" r="${p[2] * 2 * k}" fill="${o.glint}" opacity=".75"/>`).join('') +
        eyes.map((p) => `<circle cx="${p[0]}" cy="${p[1]}" r="${p[2] * 2.1}" fill="${o.eye}"/>`).join('') + '</g>';
      glints += pores.map((p) => `<circle cx="${p[0]}" cy="${p[1]}" r="${p[2] * 0.8 * k}" fill="#ffd1e0"/>`).join('');
      glints += eyes.map((p) => `<circle cx="${p[0]}" cy="${p[1]}" r="${p[2]}" fill="${o.eye}"/><circle cx="${p[0] - p[2] * 0.25}" cy="${p[1] - p[2] * 0.25}" r="${p[2] * 0.42}" fill="#ffe6e6"/>`).join('');
    }
    const edge = o.edge ? `<path d="${SIL_D}" fill="${o.edge}" opacity="${o.edgeOpacity}" filter="url(#${id}-edge)"/>` : '';
    return `
<defs>
  <clipPath id="${id}-clip"><path d="${BODY_D}"/></clipPath>
  <clipPath id="${id}-sil"><path d="${SIL_D}"/></clipPath>
  <radialGradient id="${id}-abd" cx="0.42" cy="0.3" r="0.8"><stop offset="0" stop-color="${o.plate}"/><stop offset="1" stop-color="${o.base}"/></radialGradient>
  <radialGradient id="${id}-tho" cx="0.4" cy="0.3" r="0.8"><stop offset="0" stop-color="${o.plate}"/><stop offset="1" stop-color="${o.base}"/></radialGradient>
  <linearGradient id="${id}-sheen" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="${o.sheen}" stop-opacity="0"/><stop offset=".4" stop-color="${o.sheen}" stop-opacity="${o.sheenOpacity}"/><stop offset=".62" stop-color="${o.sheen}" stop-opacity="0"/></linearGradient>
  <filter id="${id}-glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="7"/></filter>
  <filter id="${id}-edge" x="-5%" y="-5%" width="110%" height="110%"><feMorphology operator="erode" radius="${o.edgeW}" in="SourceAlpha" result="er"/><feGaussianBlur in="er" stdDeviation="${o.edgeW * 0.6}" result="erb"/><feComposite in="SourceGraphic" in2="erb" operator="out"/></filter>
</defs>
<path d="${SIL_D}" fill="${o.base}"/>
<g clip-path="url(#${id}-clip)">
  <ellipse cx="0" cy="200" rx="160" ry="200" fill="url(#${id}-abd)"/>
  <ellipse cx="0" cy="-26" rx="126" ry="74" fill="url(#${id}-tho)"/>
  <ellipse cx="0" cy="-150" rx="90" ry="50" fill="url(#${id}-tho)"/>
  <path d="M-160,50 L-34,50 L-34,420 L-160,420Z" fill="url(#${id}-sheen)"/>
  <path d="M-120,-80 L-24,-80 L-24,30 L-120,30Z" fill="url(#${id}-sheen)"/>
  ${seams}
  <path d="M-70,-80 Q0,-56 70,-80" fill="none" stroke="${o.seam}" stroke-width="8" opacity=".75"/>
  <path d="M-40,32 Q0,50 40,32" fill="none" stroke="${o.seam}" stroke-width="7" opacity=".7"/>
  <path d="M0,-176 L0,-110 M0,-62 L0,26" stroke="${o.seam}" stroke-width="6" opacity=".7"/>
</g>
${edge}
${glints}`;
  }

  window.BUG = { BODY_D, LIMBS_D, SIL_D, TIPS, detailed, smooth, limb };
})();
