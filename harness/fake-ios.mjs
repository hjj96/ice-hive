// Fake iOS shell for the harness (--fake-ios): reproduces what Capacitor's iOS WebView injects at document start
// (window.Capacitor globals, the real native-bridge.js from @capacitor/ios, one PluginHeader per plugin), with a
// JavaScript stand-in for the native side behind window.webkit.messageHandlers.bridge.
//
// Plugin headers are parsed from the plugins' own Swift sources, so method names / return types match the device.
// In the page: window.__fakeNative = { calls, prefs, listeners, fire(pluginId, eventName, data) }.
import fs from 'node:fs';
import path from 'node:path';

const PLUGINS = ['app', 'haptics', 'preferences', 'splash-screen', 'status-bar'];
const RTYPE = { CAPPluginReturnPromise: 'promise', CAPPluginReturnCallback: 'callback', CAPPluginReturnNone: null };

export function pluginHeaders(root) {
  const out = [];
  for (const id of PLUGINS) {
    const dir = path.join(root, 'node_modules', '@capacitor', id, 'ios', 'Sources');
    const files = [];
    (function walk(d) { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (e.name.endsWith('Plugin.swift')) files.push(p); } })(dir);
    for (const f of files) {
      const src = fs.readFileSync(f, 'utf8');
      const js = /jsName\s*=\s*"([^"]+)"/.exec(src);
      if (!js) continue;
      // default methods every CAPPlugin exports (JSExport.createPluginHeader)
      const methods = [{ name: 'addListener' }, { name: 'removeListener' }, { name: 'removeAllListeners', rtype: 'promise' },
        { name: 'checkPermissions', rtype: 'promise' }, { name: 'requestPermissions', rtype: 'promise' }];
      for (const m of src.matchAll(/CAPPluginMethod\(name:\s*"([^"]+)",\s*returnType:\s*(\w+)\)/g)) {
        const rtype = RTYPE[m[2]];
        methods.push(rtype ? { name: m[1], rtype } : { name: m[1] });
      }
      out.push({ name: js[1], methods });
    }
  }
  return out;
}

export function fakeIosInitScript(root, { prefs = {}, delayMs = 0 } = {}) {
  const bridge = fs.readFileSync(path.join(root, 'node_modules', '@capacitor', 'ios', 'Capacitor', 'Capacitor', 'assets', 'native-bridge.js'), 'utf8');
  const headers = pluginHeaders(root);
  const fake = `
(function () {
  // 1. JSExport.exportCapacitorGlobalJS
  window.Capacitor = { DEBUG: false, isLoggingEnabled: false, Plugins: {} };
  window.WEBVIEW_SERVER_URL = 'capacitor://localhost';
  // 2. the native side (WKScriptMessageHandler 'bridge') — JavaScript stand-in
  var prefs = ${JSON.stringify(prefs)};
  var DELAY = ${Number(delayMs) || 0};
  var calls = [], listeners = [];
  function log(s) { try { if (window.__harnessNative) window.__harnessNative(s); } catch (e) {} }
  function reply(data, result, delay) {
    setTimeout(function () {
      var r = { callbackId: data.callbackId, pluginId: data.pluginId, methodName: data.methodName, success: true };
      for (var k in result) r[k] = result[k];
      window.Capacitor.fromNative(r);
    }, delay || 0);
  }
  var has = function (o, k) { return Object.prototype.hasOwnProperty.call(o, k); };
  var impl = {
    Preferences: {
      configure: function () { return {}; },
      get: function (o) { return { value: has(prefs, o.key) ? prefs[o.key] : null }; },
      set: function (o) { prefs[o.key] = String(o.value); return {}; },
      remove: function (o) { delete prefs[o.key]; return {}; },
      keys: function () { return { keys: Object.keys(prefs) }; },
      clear: function () { for (var k in prefs) delete prefs[k]; return {}; },
      migrate: function () { return { migrated: [], existing: [] }; },
      removeOld: function () { return {}; },
    },
    Haptics: { impact: function () { return {}; }, notification: function () { return {}; }, selectionStart: function () { return {}; },
      selectionChanged: function () { return {}; }, selectionEnd: function () { return {}; }, vibrate: function () { return {}; } },
    SplashScreen: { show: function () { return {}; }, hide: function () { return {}; } },
    StatusBar: { hide: function () { return {}; }, show: function () { return {}; }, setStyle: function () { return {}; },
      setBackgroundColor: function () { return {}; }, setOverlaysWebView: function () { return {}; },
      getInfo: function () { return { visible: false, style: 'DARK', overlays: false }; } },
    App: { getInfo: function () { return { name: 'Ледяной Улей', id: 'com.hjj96.icehive', build: '1', version: '1.0.0' }; },
      getState: function () { return { isActive: true }; }, getLaunchUrl: function () { return {}; },
      exitApp: function () { return {}; }, minimizeApp: function () { return {}; } },
  };
  window.webkit = { messageHandlers: { bridge: { postMessage: function (data) {
    if (!data || (data.type && data.type !== 'message')) return;   // js.error reports etc.
    if (data.pluginId === 'Console') return;                         // console mirroring
    var entry = { t: Math.round(performance.now()), plugin: data.pluginId, method: data.methodName, options: data.options || {} };
    calls.push(entry);
    log(entry.plugin + '.' + entry.method + ' ' + JSON.stringify(entry.options));
    if (data.methodName === 'addListener') { listeners.push({ pluginId: data.pluginId, eventName: data.options.eventName, callbackId: data.callbackId }); return; }
    if (data.methodName === 'removeListener') { listeners = listeners.filter(function (l) { return l.callbackId !== data.options.callbackId; }); reply(data, { data: {} }); return; }
    if (data.methodName === 'removeAllListeners') { listeners = listeners.filter(function (l) { return l.pluginId !== data.pluginId; }); reply(data, { data: {} }); return; }
    var p = impl[data.pluginId], fn = p && p[data.methodName];
    if (!fn) { reply(data, { success: false, error: { message: 'fake-ios: not implemented ' + data.pluginId + '.' + data.methodName } }); return; }
    var out;
    try { out = fn(data.options || {}); } catch (e) { reply(data, { success: false, error: { message: String(e) } }); return; }
    reply(data, { data: out }, data.pluginId === 'Preferences' ? DELAY : 0);
  } } } };
  window.__fakeNative = {
    calls: calls, prefs: prefs,
    get listeners() { return listeners.slice(); },
    fire: function (pluginId, eventName, data) {
      var n = 0;
      listeners.forEach(function (l) {
        if (l.pluginId !== pluginId || l.eventName !== eventName) return;
        n++;
        window.Capacitor.fromNative({ callbackId: l.callbackId, pluginId: pluginId, methodName: 'addListener', success: true, data: data || {}, save: true });
      });
      return n;
    },
  };
  // native-bridge.js asks synchronously (WKUIDelegate prompt) whether CapacitorCookies / CapacitorHttp are on: no
  var prompt0 = window.prompt;
  window.prompt = function (msg) {
    try { var o = JSON.parse(msg); if (o && typeof o.type === 'string' && o.type.indexOf('Capacitor') === 0) return 'false'; } catch (e) {}
    return prompt0 ? prompt0.apply(window, arguments) : null;
  };
})();
`;
  // 4. JSExport.exportJS: one PluginHeader per registered plugin
  const hdr = headers.map((h) => `(function(w){var a=(w.Capacitor=w.Capacitor||{});var h=(a.PluginHeaders=a.PluginHeaders||[]);h.push(${JSON.stringify(h)});})(window);`).join('\n');
  // 3. the real native-bridge.js shipped inside Capacitor.framework
  return fake + '\n' + bridge + '\n' + hdr + '\n';
}
