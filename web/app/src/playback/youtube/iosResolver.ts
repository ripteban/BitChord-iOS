import type { Innertube, Misc, YT } from 'youtubei.js/web';
import { ytAuthSnapshot } from '@/extension/useYtAuth';
import { trackLog } from '../trackLog';

/**
 * iOS app: finds a client whose audio URL really streams the whole track, the
 * way yt-dlp picks its clients, and proves it before playing.
 *
 * What a phone showed (diagnostics, 2026-11-25, on a carrier's shared address):
 * anonymous clients are bot-checked, and the signed-in web clients hand out
 * URLs googlevideo refuses past 1 MiB while their PO tokens aren't accepted.
 * yt-dlp's answer for a signed-in user is the TV client (no PO token, takes
 * the account's cookies). So each candidate is asked for the track, its best
 * AAC URL is deciphered, and a range past the 1 MiB wall is requested: the
 * first client that answers 206 plays. The winner is tried first next time.
 */

interface Spec {
  name: string;
  clientName: string;
  clientVersion: string;
  /** X-Youtube-Client-Name. */
  id: string;
  userAgent: string;
  signed: boolean;
  extra?: Record<string, unknown>;
  embedded?: boolean;
}

const COBALT = 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version';
const SAFARI = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
const QUEST = 'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip';

/** yt-dlp's client table (yt_dlp/extractor/youtube/_base.py), the ones that need no PO token. */
const SPECS: Spec[] = [
  {
    name: 'VISIONOS',
    clientName: 'VISIONOS',
    clientVersion: '1.02',
    id: '101',
    userAgent: SAFARI,
    signed: false,
    extra: { deviceMake: 'Apple', deviceModel: 'RealityDevice17,1', osName: 'visionOS', osVersion: '26.5.23O471' },
  },
  { name: 'TV_DOWNGRADED+account', clientName: 'TVHTML5', clientVersion: '5.20260114', id: '7', userAgent: COBALT, signed: true },
  { name: 'TV+account', clientName: 'TVHTML5', clientVersion: '7.20260311.12.00', id: '7', userAgent: COBALT, signed: true },
  {
    name: 'TV_EMBEDDED+account',
    clientName: 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
    clientVersion: '2.0',
    id: '85',
    userAgent: COBALT,
    signed: true,
    embedded: true,
  },
  { name: 'TV_SIMPLY+account', clientName: 'TVHTML5_SIMPLY', clientVersion: '1.0', id: '75', userAgent: COBALT, signed: true },
  {
    name: 'ANDROID_VR',
    clientName: 'ANDROID_VR',
    clientVersion: '1.65.10',
    id: '28',
    userAgent: QUEST,
    signed: false,
    extra: { deviceMake: 'Oculus', deviceModel: 'Quest 3', androidSdkVersion: 32, osName: 'Android', osVersion: '12L' },
  },
  { name: 'TV_SIMPLY', clientName: 'TVHTML5_SIMPLY', clientVersion: '1.0', id: '75', userAgent: COBALT, signed: false },
  { name: 'TV_DOWNGRADED', clientName: 'TVHTML5', clientVersion: '5.20260114', id: '7', userAgent: COBALT, signed: false },
];

type Native = { postMessage: (message: unknown) => Promise<unknown> };
type Reply<T> = { ok: true; result: T } | { ok: false; error: { code: string; message: string } };

function native(): Native | null {
  return (window as Window & { webkit?: { messageHandlers?: { bitchord?: Native } } }).webkit?.messageHandlers?.bitchord ?? null;
}

async function call<T>(method: string, params: Record<string, unknown>): Promise<T> {
  const handler = native();
  if (!handler) throw new Error('no native bridge');
  const reply = (await handler.postMessage({ kind: 'bridge', method, params })) as Reply<T>;
  if (!reply?.ok) throw new Error(reply?.error?.message ?? `${method} failed`);
  return reply.result;
}

export interface VerifiedStream {
  /** The spec's name, for the log and stats ("TV_DOWNGRADED+account"). */
  client: string;
  signed: boolean;
  info: YT.VideoInfo;
  format: Misc.Format;
  /** Deciphered, proven past the 1 MiB wall. */
  url: string;
}

const WINNER_KEY = 'bitchord:ios:client';
/** Specs that just failed for a reason about the visitor (bot check, refused stream): skipped for a while. */
const benched = new Map<string, number>();
const BENCH_MS = 10 * 60_000;
/** Per track: clients whose stream broke mid-play. */
const broken = new Map<string, Set<string>>();

export function markBroken(videoId: string, client: string) {
  const set = broken.get(videoId) ?? new Set<string>();
  set.add(client);
  broken.set(videoId, set);
  benched.set(client, Date.now() + BENCH_MS);
  if (localStorage.getItem(WINNER_KEY) === client) localStorage.removeItem(WINNER_KEY);
}

function candidates(videoId: string): Spec[] {
  const signedIn = ytAuthSnapshot().signedIn;
  const now = Date.now();
  const winner = localStorage.getItem(WINNER_KEY);
  return SPECS.filter((s) => (!s.signed || signedIn) && !(broken.get(videoId)?.has(s.name)) && (benched.get(s.name) ?? 0) <= now).sort(
    (a, b) => Number(b.name === winner) - Number(a.name === winner),
  );
}

async function ask(yt: Innertube, videoId: string, spec: Spec): Promise<unknown> {
  const session = yt.session.context.client;
  const body = {
    context: {
      client: {
        clientName: spec.clientName,
        clientVersion: spec.clientVersion,
        userAgent: spec.userAgent,
        hl: session.hl ?? 'en',
        gl: session.gl ?? 'US',
        timeZone: session.timeZone,
        utcOffsetMinutes: session.utcOffsetMinutes,
        ...(spec.signed ? {} : { visitorData: session.visitorData }),
        ...spec.extra,
      },
      user: { lockedSafetyMode: false },
      ...(spec.embedded && { thirdParty: { embedUrl: 'https://www.youtube.com/' } }),
    },
    videoId,
    contentCheckOk: true,
    racyCheckOk: true,
    playbackContext: {
      contentPlaybackContext: { html5Preference: 'HTML5_PREF_WANTS', signatureTimestamp: yt.session.player?.signature_timestamp },
    },
  };
  const response = await call<{ status: number; body: string }>('ios.http', {
    url: 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
    method: 'POST',
    auth: spec.signed,
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': spec.userAgent,
      'X-Youtube-Client-Name': spec.id,
      'X-Youtube-Client-Version': spec.clientVersion,
      ...(!spec.signed && session.visitorData ? { 'X-Goog-Visitor-Id': session.visitorData } : {}),
    },
    body: JSON.stringify(body),
  });
  if (response.status !== 200) throw new Error(`HTTP ${response.status}`);
  return JSON.parse(response.body);
}

/**
 * The first client that proves it can stream [videoId] whole, or null when
 * none does (the caller falls back to the web app's own resolver).
 */
export async function resolveVerified(yt: Innertube, videoId: string): Promise<VerifiedStream | null> {
  const sessionPlayer = yt.session.player;
  if (!native() || !sessionPlayer) return null;
  const { Utils, YT } = await import('youtubei.js/web');
  const report: string[] = [];

  for (const spec of candidates(videoId)) {
    const started = performance.now();
    const ms = () => `${Math.round(performance.now() - started)}ms`;
    try {
      const data = await ask(yt, videoId, spec);
      const info = new YT.VideoInfo([{ success: true, status_code: 200, data } as never], yt.actions, Utils.generateRandomString(16));
      const status = info.playability_status?.status;
      if (status !== 'OK') {
        const reason = info.playability_status?.reason ?? status ?? 'no status';
        report.push(`${spec.name}: ${reason}`);
        if (/not a bot|sign in|reloaded/i.test(reason)) benched.set(spec.name, Date.now() + BENCH_MS);
        continue;
      }
      const format = (info.streaming_data?.adaptive_formats ?? [])
        .filter((f) => f.has_audio && !f.has_video && /^audio\/mp4/.test(f.mime_type ?? '') && !f.is_drc)
        .sort((a, b) => (b.bitrate ?? 0) - (a.bitrate ?? 0))[0];
      if (!format) {
        report.push(`${spec.name}: no AAC audio`);
        continue;
      }
      const url = await format.decipher(sessionPlayer);
      // Past the 1 MiB wall an unaccepted stream stops at, or the tail of a shorter file.
      const length = Number(format.content_length ?? 0);
      const offset = length > 0 ? Math.max(0, Math.min(length - 2048, 1_400_000)) : 1_400_000;
      const probe = await call<{ status: number; bytes: number }>('ios.probe', { url, offset });
      if (probe.status !== 206 && probe.status !== 200) {
        report.push(`${spec.name}: stream refused (HTTP ${probe.status} at byte ${offset})`);
        benched.set(spec.name, Date.now() + BENCH_MS);
        continue;
      }
      trackLog.i(`verified ${spec.name} in ${ms()} (HTTP ${probe.status} at byte ${offset} of ${length})${report.length ? `; before it: ${report.join(' | ')}` : ''}`, videoId);
      localStorage.setItem(WINNER_KEY, spec.name);
      return { client: spec.name, signed: spec.signed, info, format, url };
    } catch (error) {
      report.push(`${spec.name}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  trackLog.w(`no verified client: ${report.join(' | ') || 'none to try'}`, videoId);
  return null;
}
