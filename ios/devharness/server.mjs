// Desktop test bench for the iOS shell: serves the built web app the way
// AppSchemeHandler.swift does (static files + /__net/ proxy) and answers the
// injected shim's native calls the way Bridge.swift does, over HTTP.
//
//   node ios/devharness/server.mjs <web/app/dist> [port]
//
// Open http://localhost:5180 in a browser at phone size.
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));
const dist = resolve(process.argv[2] ?? 'dist');
const port = Number(process.argv[3] ?? 5180);
const injectSource = await readFile(join(here, '..', 'BitChord', 'inject.js'), 'utf8');

// Stands in for window.webkit.messageHandlers.bitchord in a desktop browser.
const polyfill = `
window.webkit = { messageHandlers: { bitchord: { postMessage: (m) =>
  fetch('/__native', { method: 'POST', body: JSON.stringify(m) }).then(async (r) => {
    const j = await r.json(); if (j.error) throw new Error(j.error); return j.reply; }) } } };
`;

const DROPPED = new Set(['origin', 'referer', 'x-origin', 'host', 'cookie', 'content-length', 'connection',
  'accept-encoding', 'sec-fetch-dest', 'sec-fetch-mode', 'sec-fetch-site', 'sec-ch-ua', 'sec-ch-ua-mobile',
  'sec-ch-ua-platform', 'user-agent']);

function extraHeaders(url, youtubeOriginForApi = false) {
  const u = new URL(url);
  const imp = (o, x = true) => ({ Origin: o, Referer: o + '/', ...(x ? { 'X-Origin': o } : {}) });
  if (u.host === 'music.youtube.com' && u.pathname.startsWith('/youtubei/')) return imp('https://music.youtube.com');
  if (u.host === 'www.youtube.com' && u.pathname.startsWith('/youtubei/')) return imp('https://www.youtube.com');
  if (u.host === 'www.youtube.com' && u.pathname.startsWith('/api/jnn/')) return youtubeOriginForApi ? imp('https://www.youtube.com', false) : {};
  if (u.host === 's.youtube.com') return imp('https://music.youtube.com', false);
  if (u.host.endsWith('googlevideo.com')) {
    const c = u.searchParams.get('c') ?? '';
    if (c === 'VISIONOS') return {};
    if (c === 'ANDROID_VR') return { 'User-Agent': 'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip' };
    if (c.startsWith('TVHTML5')) return { ...imp('https://www.youtube.com', false), 'User-Agent': 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version' };
    return imp('https://www.youtube.com', false);
  }
  if (u.host === 'amp-api.music.apple.com') return imp('https://music.apple.com', false);
  if (u.host.endsWith('musixmatch.com')) return { Cookie: 'mxm_bab=AB' };
  return {};
}

async function upstream(url, method, headers, body, ytApi = false) {
  const h = {};
  let ua = null;
  for (const [k, v] of Object.entries(headers ?? {})) {
    if (k.toLowerCase() === 'user-agent') { if (!/Chrome|Electron/.test(String(v))) ua = v; continue; }
    if (!DROPPED.has(k.toLowerCase())) h[k] = v;
  }
  h['User-Agent'] = ua ?? 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
  Object.assign(h, extraHeaders(url, ytApi));
  return fetch(url, { method, headers: h, body: method === 'GET' || method === 'HEAD' ? undefined : body, redirect: 'follow' });
}

function pageHeaders(res) {
  const out = {};
  const encoded = !!res.headers.get('content-encoding');
  res.headers.forEach((v, k) => {
    if (k === 'content-encoding' || k === 'transfer-encoding' || k === 'set-cookie' || k.startsWith('access-control-')) return;
    if (encoded && k === 'content-length') return;
    out[k] = v;
  });
  out['access-control-allow-origin'] = '*';
  out['access-control-expose-headers'] = '*';
  out['x-bitchord-final-url'] = res.url;
  return out;
}

async function httpExchange(p, ytApi) {
  const body = p.body === undefined ? undefined : p.bodyEncoding === 'base64' ? Buffer.from(p.body, 'base64') : p.body;
  const res = await upstream(p.url, (p.method ?? 'GET').toUpperCase(), p.headers, body, ytApi);
  const buf = Buffer.from(await res.arrayBuffer());
  const headers = {};
  res.headers.forEach((v, k) => (headers[k] = v));
  const textual = /json|text|javascript|xml/.test(headers['content-type'] ?? '');
  return { status: res.status, headers, url: res.url, bodyEncoding: textual ? 'text' : 'base64', body: textual ? buf.toString('utf8') : buf.toString('base64') };
}

const ok = (result) => ({ ok: true, result });
/** The iOS app's offline store, in memory. */
const offline = new Map();
const fail = (code, message) => ({ ok: false, error: { code, message } });

async function bridge(method, params) {
  try {
    switch (method) {
      case 'ping': return ok({ version: 'ios-1.0', protocol: 1, browser: 'firefox', capabilities: ['yt', 'lyrics'] });
      case 'yt.fetch':
        if (params.auth) return fail('unauthenticated', 'not in iOS yet');
        if (!String(params.url).startsWith('https://www.youtube.com/api/jnn/')) return fail('forbidden', 'nope');
        return ok(await httpExchange(params, true));
      case 'yt.authState': return ok({ browserSignedIn: false, connected: false, signedIn: false, accounts: [], active: null, problem: null });
      case 'ios.offlineList': return ok([...offline.values()].map(({ data, ...meta }) => meta));
      case 'ios.offlineSave': {
        const data = Buffer.from(params.data, 'base64');
        const entry = { videoId: params.videoId, title: params.title, artist: params.artist, album: params.album ?? null,
          artworkUrl: params.artworkUrl ?? null, durationSec: params.durationSec ?? 0, permanent: !!params.permanent,
          bytes: data.length, savedAt: Date.now(), data };
        offline.set(params.videoId, entry);
        console.log(`[offline] saved ${params.videoId} ${data.length} bytes permanent=${entry.permanent}`);
        const { data: _, ...meta } = entry; return ok(meta);
      }
      case 'ios.offlinePin': { const e = offline.get(params.videoId); if (!e) return fail('internal', 'not saved'); e.permanent = true; const { data: _, ...meta } = e; return ok(meta); }
      case 'ios.offlineDelete': offline.delete(params.videoId); return ok({});
      case 'ios.http':
        if (params.auth) return fail('unauthenticated', 'no account in the desktop harness');
        return ok(await httpExchange(params, false));
      case 'ios.probe': {
        const res = await upstream(params.url, 'GET', { Range: `bytes=${params.offset}-${params.offset + 1023}` });
        const buf = await res.arrayBuffer();
        return ok({ status: res.status, bytes: buf.byteLength });
      }
      case 'lyrics.fetch': return ok(await httpExchange(params, false));
      case 'lyrics.permissions': return ok({ granted: params.origins ?? [] });
      case 'lyrics.requestPermissions': return ok({});
      default: return fail('unsupported', `${method} isn't available in the iOS app.`);
    }
  } catch (e) {
    return fail('network', String(e));
  }
}

async function native(msg) {
  if (msg.kind === 'log') { if (msg.level !== 'log') console.log(`[js:${msg.level}]`, msg.message.slice(0, 400)); return null; }
  if (msg.kind === 'bridge') return bridge(msg.method, msg.params ?? {});
  if (msg.kind === 'fetch') {
    const res = await upstream(msg.url, msg.method, msg.headers, msg.body ? Buffer.from(msg.body, 'base64') : undefined);
    const buf = Buffer.from(await res.arrayBuffer());
    return { status: res.status, statusText: res.statusText, headers: pageHeaders(res), url: res.url, body: buf.toString('base64') };
  }
  throw new Error('unknown kind');
}

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.wasm': 'application/wasm', '.png': 'image/png', '.webp': 'image/webp' };

createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${port}`);
  try {
    if (url.pathname === '/__native') {
      const chunks = []; for await (const c of req) chunks.push(c);
      const reply = await native(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ reply }));
      return;
    }
    if (url.pathname.startsWith('/__local/')) {
      const e = offline.get(decodeURIComponent(url.pathname.slice(9)));
      if (!e) { res.writeHead(404).end('Not saved'); return; }
      const m = /bytes=(\d+)-(\d*)/.exec(req.headers.range ?? '');
      if (m) {
        const start = Number(m[1]); const end = m[2] ? Math.min(Number(m[2]), e.data.length - 1) : e.data.length - 1;
        res.writeHead(206, { 'content-type': 'audio/mp4', 'accept-ranges': 'bytes', 'content-range': `bytes ${start}-${end}/${e.data.length}`, 'content-length': end - start + 1 });
        res.end(e.data.subarray(start, end + 1)); return;
      }
      res.writeHead(200, { 'content-type': 'audio/mp4', 'accept-ranges': 'bytes', 'content-length': e.data.length }).end(e.data); return;
    }
    if (url.pathname.startsWith('/__net/')) {
      const target = url.searchParams.get('u');
      const chunks = []; for await (const c of req) chunks.push(c);
      const up = await upstream(target, req.method, req.headers, chunks.length ? Buffer.concat(chunks) : undefined);
      res.writeHead(up.status, pageHeaders(up));
      if (up.body && req.method !== 'HEAD') for await (const c of up.body) res.write(c);
      res.end();
      return;
    }
    let file = normalize(join(dist, decodeURIComponent(url.pathname)));
    if (!file.startsWith(dist)) file = join(dist, 'index.html');
    let s = await stat(file).catch(() => null);
    if (!s || s.isDirectory()) { file = join(dist, 'index.html'); s = await stat(file); }
    let data = await readFile(file);
    if (file.endsWith('index.html')) {
      data = Buffer.from(data.toString('utf8').replace('<head>', `<head><script>${polyfill}\n${injectSource}</script>`));
    }
    res.writeHead(200, { 'content-type': MIME[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-cache' }).end(data);
  } catch (e) {
    console.error(req.url, e);
    if (!res.headersSent) res.writeHead(502).end(String(e)); else res.end();
  }
}).listen(port, () => console.log(`harness on http://localhost:${port} serving ${dist}`));
