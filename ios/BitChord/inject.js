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

  // ---- console -> Xcode/simulator log (debugging) ---------------------------
  for (const level of ['log', 'info', 'warn', 'error']) {
    const original = console[level].bind(console);
    console[level] = (...args) => {
      original(...args);
      try {
        const message = args
          .map((a) => (a instanceof Error ? `${a.name}: ${a.message}\n${a.stack}` : typeof a === 'string' ? a : JSON.stringify(a)))
          .join(' ')
          .slice(0, 2000);
        native.postMessage({ kind: 'log', level, message }).catch(() => {});
      } catch {}
    };
  }
  window.addEventListener('error', (e) => console.error('[uncaught]', e.message, e.filename + ':' + e.lineno));
  window.addEventListener('unhandledrejection', (e) => console.error('[unhandled rejection]', e.reason));

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

  const nativeFetch = window.fetch.bind(window);
  window.fetch = async function (input, init) {
    const rawUrl = typeof input === 'string' ? input : input instanceof URL ? input.href : input && input.url;
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
    const body = NULL_BODY.has(status) ? null : fromBase64(result.body);
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

  console.info('[BitChord iOS] shim ready at', ORIGIN, 'secure:', window.isSecureContext, 'MMS:', !!window.ManagedMediaSource);
})();
