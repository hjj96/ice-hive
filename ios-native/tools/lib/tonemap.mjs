// Colour transforms of the web renderer (three.js r170): ACES filmic tone mapping (exposure 1) + linear -> sRGB.
// The web game's shader colours are linear and HDR (> 1 allowed); the native port needs them as display sRGB.
export function srgbToLinear(c) { return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
export function linearToSrgb(c) { c = Math.min(1, Math.max(0, c)); return c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055; }
function fit(v) { return (v * (v + 0.0245786) - 0.000090537) / (v * (0.983729 * v + 0.4329510) + 0.238081); }
export function aces([r, g, b], exposure = 1) {
  const k = exposure / 0.6;
  r *= k; g *= k; b *= k;
  const ir = 0.59719 * r + 0.35458 * g + 0.04823 * b, ig = 0.07600 * r + 0.90834 * g + 0.01566 * b, ib = 0.02840 * r + 0.13383 * g + 0.83777 * b;
  const fr = fit(ir), fg = fit(ig), fb = fit(ib);
  const or = 1.60475 * fr - 0.53108 * fg - 0.07367 * fb, og = -0.10208 * fr + 1.10813 * fg - 0.00605 * fb, ob = -0.00327 * fr - 0.07276 * fg + 1.07602 * fb;
  return [Math.min(1, Math.max(0, or)), Math.min(1, Math.max(0, og)), Math.min(1, Math.max(0, ob))];
}
// linear HDR colour as the web game displays it -> sRGB 0..1
export function display(rgb) { return aces(rgb).map(linearToSrgb); }
export function hexLinear(hex) { return [((hex >> 16) & 255) / 255, ((hex >> 8) & 255) / 255, (hex & 255) / 255].map(srgbToLinear); }
export function toHex(rgb) { return '#' + rgb.map(c => Math.round(Math.min(1, Math.max(0, c)) * 255).toString(16).padStart(2, '0')).join(''); }
