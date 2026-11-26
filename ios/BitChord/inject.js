// Injected at document start into the BitChord web app inside the iOS app.
// It stands in for the browser extension:
//  1. the "relay" transport of the page <-> extension bridge (web/shared/src/bridge),
//  2. the extension's network rules: cross-origin requests go through native code,
//  3. small WebKit-on-iPhone adjustments (ManagedMediaSource, AAC).
(() => {
  'use strict';
  if (window.__bitchordIOS) return;
  window.__bitchordIOS = true;

  const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bitchord;
  if (!native) return;
  const ORIGIN = location.origin;
  const CHANNEL = 'bitchord-bridge';

  // ---- diagnostics: the last few hundred console lines and errors, kept in memory.
  // Read by the app's diagnostics sheet (shake the phone) through __bitchordDiag().
  const DIAG_MAX = 400;
  const diag = [];
  const remember = (level, args) => {
    try {
      const text = Array.prototype.map
        .call(args, (a) =>
          a instanceof Error ? `${a.name}: ${a.message}` : typeof a === 'string' ? a : a && typeof a === 'object' ? (() => { try { return JSON.stringify(a).slice(0, 300); } catch { return String(a); } })() : String(a),
        )
        .join(' ')
        .slice(0, 600);
      diag.push(`${new Date().toISOString().slice(11, 23)} ${level} ${text}`);
      if (diag.length > DIAG_MAX) diag.splice(0, diag.length - DIAG_MAX);
    } catch {}
  };
  for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
    const original = console[level].bind(console);
    console[level] = (...args) => {
      remember(level, args);
      original(...args);
    };
  }
  window.addEventListener('error', (e) => remember('uncaught', [e.message, `${e.filename}:${e.lineno}`]));
  window.addEventListener('unhandledrejection', (e) => remember('rejection', [e.reason]));
  window.__bitchordDiag = () => diag.join(String.fromCharCode(10));

  // ---- console -> Xcode/simulator log (diagnostic builds only: it costs time) --
  if (window.__bitchordDebug) {
    for (const level of ['log', 'info', 'warn', 'error']) {
      const original = console[level].bind(console);
      console[level] = (...args) => {
        original(...args);
        try {
          const message = args
            .map((a) => (a instanceof Error ? `${a.name}: ${a.message}
${a.stack}` : typeof a === 'string' ? a : JSON.stringify(a)))
            .join(' ')
            .slice(0, 2000);
          native.postMessage({ kind: 'log', level, message }).catch(() => {});
        } catch {}
      };
    }
    window.addEventListener('error', (e) => console.error('[uncaught]', e.message, e.filename + ':' + e.lineno));
    window.addEventListener('unhandledrejection', (e) => console.error('[unhandled rejection]', e.reason));
  }

  // ---- an app, not a page: no zoom, no text selection or callouts on chrome ----
  const VIEWPORT = 'width=device-width, initial-scale=1, maximum-scale=1, minimum-scale=1, user-scalable=no, viewport-fit=cover';
  const lockViewport = () => {
    let meta = document.querySelector('meta[name=viewport]');
    if (!meta) {
      meta = document.createElement('meta');
      meta.name = 'viewport';
      (document.head || document.documentElement).appendChild(meta);
    }
    if (meta.content !== VIEWPORT) meta.content = VIEWPORT;
  };
  const APP_CSS = `
    html { touch-action: pan-x pan-y; -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
    * { -webkit-tap-highlight-color: transparent; }
    body { -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; overscroll-behavior: none; }
    input, textarea, select, [contenteditable=true] { -webkit-user-select: text; user-select: text; font-size: max(16px, 1em); }
    img { -webkit-user-drag: none; -webkit-touch-callout: none; }
  `;
  // The native tab bar and mini player (NativeChrome.swift) float over the page's
  // bottom: the page keeps its last rows clear of them.
  const NATIVE_CHROME_CSS = `
    :root {
      --mobile-bottom-chrome: calc(env(safe-area-inset-bottom) + 138px) !important;
      --mobile-top-bar-height: calc(env(safe-area-inset-top) + 58px) !important;
    }
  `;
  const addAppStyle = () => {
    if (document.getElementById('bitchord-ios-style')) return;
    const style = document.createElement('style');
    style.id = 'bitchord-ios-style';
    style.textContent = APP_CSS + (window.__bitchordNativeChrome ? NATIVE_CHROME_CSS : '');
    (document.head || document.documentElement).appendChild(style);
  };
  lockViewport();
  addAppStyle();
  document.addEventListener('DOMContentLoaded', () => { lockViewport(); addAppStyle(); });
  // Safari-style pinch gestures (gesturestart) never zoom the app.
  for (const type of ['gesturestart', 'gesturechange', 'gestureend']) {
    document.addEventListener(type, (e) => e.preventDefault(), { passive: false });
  }

  // ---- media: iPhone WebKit has ManagedMediaSource, not MediaSource ----------
  // AAC (itag 140) is what plays reliably there; WebM/Opus is declined so both
  // the engine's codec pick and Shaka's filter fall back to it.
  const MS = window.ManagedMediaSource || window.MediaSource;
  if (MS && typeof MS.isTypeSupported === 'function') {
    const isTypeSupported = MS.isTypeSupported.bind(MS);
    const patched = (type) => (/webm|opus|vp9|vp8/i.test(String(type)) ? false : isTypeSupported(type));
    try { MS.isTypeSupported = patched; } catch {}
    if (!window.MediaSource) {
      try { window.MediaSource = MS; } catch {}
    } else if (window.MediaSource !== MS) {
      try { window.MediaSource.isTypeSupported = patched; } catch {}
    }
  }
  // ManagedMediaSource needs remote playback off (or an AirPlay alternative source).
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    try { this.disableRemotePlayback = true; } catch {}
    try { this.setAttribute('playsinline', ''); } catch {}
    return play.apply(this, args);
  };

  // ---- Web Audio: iOS suspends contexts (no gesture, background, interruptions).
  // A suspended context routing the player (Automix) plays silence while the
  // track's time still runs. Every context is resumed on any touch, on any
  // media play, and when the app comes back (native calls __bitchordWakeAudio).
  const contexts = new Set();
  const NativeAudioContext = window.AudioContext;
  if (NativeAudioContext) {
    window.AudioContext = class extends NativeAudioContext {
      constructor(...args) {
        super(...args);
        contexts.add(this);
      }
    };
  }
  const wakeAudio = () => {
    for (const ctx of contexts) {
      if (ctx.state !== 'running' && ctx.state !== 'closed') ctx.resume().catch(() => {});
    }
  };
  window.__bitchordWakeAudio = wakeAudio;
  for (const type of ['touchend', 'click']) document.addEventListener(type, wakeAudio, { capture: true, passive: true });
  const nativePlay = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    wakeAudio();
    return nativePlay.apply(this, args);
  };

  // ---- artwork: a video's maxres thumbnail doesn't always exist; fall back to hqdefault.
  document.addEventListener('error', (event) => {
    const img = event.target;
    if (img instanceof HTMLImageElement && img.src.includes('/maxresdefault.')) {
      img.src = img.src.replace('/maxresdefault.', '/hqdefault.');
    }
  }, true);

  // ---- network --------------------------------------------------------------
  const SKIP_HOSTS = /(^|\.)(fonts\.googleapis\.com|fonts\.gstatic\.com)$/i;
  const proxyURL = (url) => `${ORIGIN}/__net/?u=${encodeURIComponent(url)}`;
  const shouldProxy = (raw) => {
    try {
      const u = new URL(raw, location.href);
      return (u.protocol === 'https:' || u.protocol === 'http:') && u.origin !== ORIGIN && !SKIP_HOSTS.test(u.hostname);
    } catch {
      return false;
    }
  };
  const NULL_BODY = new Set([101, 103, 204, 205, 304]);

  const toBase64 = (buffer) => {
    const bytes = new Uint8Array(buffer);
    let binary = '';
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  };
  const fromBase64 = (b64) => {
    const binary = atob(b64 || '');
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  };
  const withUrl = (response, url) => {
    try { Object.defineProperty(response, 'url', { value: url, configurable: true }); } catch {}
    return response;
  };

  // Lyrics translation: the lyrics view asks Google for English (tl=en, hard-coded
  // in am-lyrics). Translate into Spanish instead; romanization (dt=rm) is left alone.
  const TRANSLATE_TO = 'es';
  const retarget = (raw) => {
    if (!/^https:\/\/translate\.googleapis\.com\/translate_a\/single/.test(raw)) return raw;
    const u = new URL(raw);
    if (u.searchParams.getAll('dt').includes('t')) u.searchParams.set('tl', TRANSLATE_TO);
    return u.href;
  };

  const nativeFetch = window.fetch.bind(window);
  window.fetch = async function (input, init) {
    let rawUrl = typeof input === 'string' ? input : input instanceof URL ? input.href : input && input.url;
    if (rawUrl && rawUrl.includes('translate.googleapis.com')) {
      const target = retarget(new URL(rawUrl, location.href).href);
      if (target !== rawUrl) {
        input = typeof input === 'string' || input instanceof URL ? target : new Request(target, input);
        rawUrl = target;
      }
    }
    if (!rawUrl || !shouldProxy(rawUrl)) return nativeFetch(input, init);

    const request = new Request(input, init);
    const method = request.method.toUpperCase();
    const headers = {};
    request.headers.forEach((v, k) => (headers[k] = v));

    if (method === 'GET' || method === 'HEAD') {
      // Streamed through the app:// scheme handler: same origin, ranges and aborts work.
      const response = await nativeFetch(proxyURL(request.url), {
        method,
        headers,
        signal: request.signal,
        cache: 'no-store',
        credentials: 'omit',
      });
      const finalUrl = response.headers.get('x-bitchord-final-url') || request.url;
      const body = NULL_BODY.has(response.status) || method === 'HEAD' ? null : response.body;
      return withUrl(new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers }), finalUrl);
    }

    // Requests with a body go over the message channel (bodies on custom schemes are unreliable).
    if (request.signal && request.signal.aborted) throw new DOMException('Aborted', 'AbortError');
    const buffer = await request.arrayBuffer();
    const result = await native.postMessage({
      kind: 'fetch',
      url: request.url,
      method,
      headers,
      body: buffer.byteLength ? toBase64(buffer) : undefined,
    });
    if (request.signal && request.signal.aborted) throw new DOMException('Aborted', 'AbortError');
    const status = result.status;
    const body = NULL_BODY.has(status) ? null : typeof result.text === 'string' ? result.text : fromBase64(result.body);
    return withUrl(
      new Response(body, { status, statusText: result.statusText || '', headers: result.headers || {} }),
      result.url || request.url,
    );
  };

  // XHR (hls.js and older libraries): rewrite the URL onto the proxy.
  const open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    const target = url instanceof URL ? url.href : String(url);
    return open.call(this, method, shouldProxy(target) ? proxyURL(new URL(target, location.href).href) : url, ...rest);
  };

  // <audio>/<video> pointed straight at a remote URL.
  const srcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
  if (srcDesc && srcDesc.set) {
    Object.defineProperty(HTMLMediaElement.prototype, 'src', {
      configurable: true,
      enumerable: srcDesc.enumerable,
      get() { return srcDesc.get.call(this); },
      set(value) {
        const v = String(value);
        srcDesc.set.call(this, shouldProxy(v) && /googlevideo\.com|youtube\.com/i.test(v) ? proxyURL(new URL(v, location.href).href) : value);
      },
    });
  }

  // ---- the bridge: answer the page's relay messages as the extension would ----
  window.addEventListener('message', async (event) => {
    const data = event.data;
    if (event.source !== window || !data || data.channel !== CHANNEL || data.direction !== 'to-extension') return;
    if (typeof data.id !== 'string' || typeof data.method !== 'string') return;
    let reply;
    try {
      reply = await native.postMessage({ kind: 'bridge', method: data.method, params: data.params || {} });
    } catch (error) {
      reply = { ok: false, error: { code: 'internal', message: String(error) } };
    }
    const envelope = { channel: CHANNEL, protocol: data.protocol, direction: 'to-page', id: data.id };
    window.postMessage(reply && reply.ok ? { ...envelope, ok: true, result: reply.result } : { ...envelope, ok: false, error: (reply && reply.error) || { code: 'internal', message: 'no reply' } }, '*');
  });

  if (window.__bitchordDebug) console.info('[BitChord iOS] shim ready at', ORIGIN, 'secure:', window.isSecureContext, 'MMS:', !!window.ManagedMediaSource);
})();
