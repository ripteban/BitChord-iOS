import type { ApiResponse, Innertube, YT } from 'youtubei.js/web';
import { trackLog } from '../trackLog';
import { botguard } from './botguard';
import { isIOSApp } from '@/lib/platform';
import { ytAuthSnapshot } from '@/extension/useYtAuth';

/**
 * Which identity asks YouTube for a track, in order (prompt §5.2 step 5,
 * following StreamResolver.kt / InnerTubeXResolver.kt).
 *
 * InnerTubeX's automatic catalog leads with VISIONOS, then the TV clients,
 * then WEB_REMIX and the other web clients. Measured from a browser-shaped
 * request (text/plain, Chrome UA, 2026-10-15): VISIONOS, YTMUSIC (YouTube.js's
 * name for WEB_REMIX), WEB and MWEB all answer OK with a SABR URL; TV answers
 * "The page needs to be reloaded" and WEB_EMBEDDED "This video is unavailable",
 * so those two are left out. googlevideo's own SABR example uses VISIONOS.
 */
export const CLIENT_ORDER = ['VISIONOS', 'YTMUSIC', 'WEB', 'MWEB'] as const;
export type PlayerClientName = (typeof CLIENT_ORDER)[number];

/**
 * The BotGuard (WebPO) clients. As on Android (PoTokenGenerator /
 * InnerTubeX's WEB_BOTGUARD provider), they get two tokens: one bound to the
 * session's visitor data for the player request, and one bound to the
 * videoId for the stream. VISIONOS is not one of them.
 */
const WEBPO_CLIENTS: ReadonlySet<PlayerClientName> = new Set(['YTMUSIC', 'WEB', 'MWEB']);

export function usesWebPo(client: PlayerClientName): boolean {
  return WEBPO_CLIENTS.has(client);
}

/** The player-request token for [client], or undefined for a client that doesn't take one. */
/**
 * iOS app, signed in: the account's DATASYNC_ID (first part), which the app
 * reads from YouTube Music's page (YouTubeAuth.swift). A signed-in session's
 * PO tokens are bound to the account, not to the anonymous visitor: bound to
 * the visitor, YouTube kept refusing the stream past its first 512 KB.
 */
export function accountBinding(): string | null {
  if (!isIOSApp()) return null;
  const state = ytAuthSnapshot() as ReturnType<typeof ytAuthSnapshot> & { dataSyncId?: string | null };
  return state.signedIn && state.dataSyncId ? state.dataSyncId : null;
}

async function playerRequestToken(
  yt: Innertube,
  client: PlayerClientName,
  { signed = false, force = false }: { signed?: boolean; force?: boolean } = {},
): Promise<string | undefined> {
  if (!WEBPO_CLIENTS.has(client) && !force) return undefined;
  const account = signed ? accountBinding() : null;
  if (account) return botguard.mint(account);
  const visitorData = yt.session.context.client.visitorData;
  if (!visitorData) return undefined;
  return botguard.mint(decodeURIComponent(visitorData));
}

/** The streaming token (`pot`) for a media URL: bound to the account when signed in (iOS app), else to the videoId. */
export function streamingToken(videoId: string, signed: boolean): Promise<string | undefined> {
  return botguard.mint((signed && accountBinding()) || videoId);
}

/** StreamResolver: how many clients are worth trying for one track. */
export const CLIENT_ATTEMPTS = 3;
/** InnerTubeXResolver.EXCLUDE_MS: a client that refused a track sits out for this long. */
// In the iOS app a refusal is often the network's (a phone carrier's shared
// address tripping YouTube's bot check), not the track's: ask again sooner.
const EXCLUDE_MS = (isIOSApp() ? 2 : 10) * 60_000;
/** StreamResolver.UNPLAYABLE_TTL_MS: a settled "no" isn't asked again for this long. */
const UNPLAYABLE_TTL_MS = (isIOSApp() ? 2 : 10) * 60_000;
const MAX_REMEMBERED = 64;

/**
 * A track no client will play, for a reason that will read the same in ten
 * seconds: an age gate, a region block, a takedown. Its own type so callers
 * can tell it from a failure worth retrying (StreamResolver's
 * PermanentlyUnplayableException).
 */
export class UnplayableError extends Error {
  override readonly name = 'UnplayableError';

  /** An age gate, which a signed-in request may get past (prompt §5.3). */
  readonly ageGated: boolean;

  constructor(message: string, ageGated = false) {
    super(message);
    this.ageGated = ageGated;
  }
}

/** A client answered OK, with a stream to play (direct URLs, a SABR URL, or both). */
export interface ResolvedPlayer {
  videoId: string;
  client: PlayerClientName;
  info: YT.VideoInfo;
  /** The instance that asked, which SABR's reload requests must use too. */
  yt: Innertube;
  /** Asked as the signed-in user, through the extension. */
  signed: boolean;
}

// ---- Verdicts and exclusions ----------------------------------------------------

// Verdicts and exclusions are kept per identity: what YouTube refuses a
// visitor it may serve the signed-in user, and the other way round.
const unplayable = new Map<string, { reason: string; at: number; ageGated: boolean }>();
const excluded = new Map<string, Map<PlayerClientName, number>>();

const keyOf = (videoId: string, signed: boolean) => (signed ? `${videoId}#signed` : videoId);

function knownVerdict(videoId: string, signed: boolean): { reason: string; ageGated: boolean } | null {
  const key = keyOf(videoId, signed);
  const verdict = unplayable.get(key);
  if (!verdict) return null;
  if (Date.now() - verdict.at < UNPLAYABLE_TTL_MS) return verdict;
  unplayable.delete(key);
  return null;
}

export function unplayableReason(videoId: string, signed = false): string | null {
  return knownVerdict(videoId, signed)?.reason ?? null;
}

function rememberUnplayable(videoId: string, signed: boolean, reason: string, ageGated: boolean) {
  if (unplayable.size > MAX_REMEMBERED) unplayable.clear();
  unplayable.set(keyOf(videoId, signed), { reason, at: Date.now(), ageGated });
  trackLog.w(`not playable${signed ? ' signed in' : ''}: ${reason}; not asking again for 10 minutes`, videoId);
}

/** Records that [client] failed [videoId], so the next walk skips it for a while. */
export function excludeClient(videoId: string, client: PlayerClientName, why: string, signed = false) {
  trackLog.w(`${client}${signed ? ' (signed in)' : ''} refused: ${why}; skipping it for this track`, videoId);
  const key = keyOf(videoId, signed);
  let entries = excluded.get(key);
  if (!entries) {
    if (excluded.size > MAX_REMEMBERED) excluded.clear();
    entries = new Map();
    excluded.set(key, entries);
  }
  entries.set(client, Date.now() + EXCLUDE_MS);
}

/** Debug override (Debug page): localStorage "bitchord:debug:clients" = "YTMUSIC,WEB". */
export const DEBUG_CLIENTS_KEY = 'bitchord:debug:clients';

function clientOrder(): readonly PlayerClientName[] {
  const forced = localStorage.getItem(DEBUG_CLIENTS_KEY)
    ?.split(',')
    .map((c) => c.trim())
    .filter((c): c is PlayerClientName => (CLIENT_ORDER as readonly string[]).includes(c));
  return forced?.length ? forced : CLIENT_ORDER;
}

/**
 * Signed in, the web clients go first: they are the ones YouTube accepts the
 * SAPISIDHASH session on, and the phone plays age-restricted tracks the same
 * way (WEB_REMIX with cookies, InnerTubeX). VISIONOS follows in case the
 * session is honoured there too.
 */
const SIGNED_ORDER: readonly PlayerClientName[] = isIOSApp()
  ? // iOS app: VISIONOS doesn't take a signed-in session (HTTP 400, seen on a
    // phone); the web clients do, with PO tokens bound to the account.
    ['WEB', 'YTMUSIC']
  : ['YTMUSIC', 'WEB', 'VISIONOS'];

export function clientsFor(videoId: string, signed = false): PlayerClientName[] {
  const entries = excluded.get(keyOf(videoId, signed));
  const now = Date.now();
  return (signed ? SIGNED_ORDER : clientOrder()).filter((client) => {
    const until = entries?.get(client);
    return until === undefined || until <= now;
  });
}

/** Signing in or out changes what YouTube will serve; old verdicts don't apply (StreamResolver.onSessionChanged). */
export function onSessionChanged() {
  unplayable.clear();
  excluded.clear();
}

// ---- The player request ------------------------------------------------------

/**
 * Asks [client] for [videoId]'s player response. The parameters follow
 * googlevideo's example; `reloadPlaybackContext` is set when the SABR server
 * asks for a fresh response mid-stream.
 *
 * No `adPlaybackContext`. Kira sends `{ pyv: true }`, and with it YouTube
 * mints streams that googlevideo cuts off after ~1.3 MB, about 70s of audio
 * (measured 2026-10-15: 4 of 4 VISIONOS URLs refused a range past that point
 * with it, 0 of 4 without; the browser saw the same wall over SABR).
 */
export async function playerRequest(
  yt: Innertube,
  videoId: string,
  client: PlayerClientName,
  reloadPlaybackContext?: unknown,
  options: { signed?: boolean; force?: boolean } = {},
): Promise<ApiResponse> {
  const poToken = await playerRequestToken(yt, client, options);
  return yt.actions.execute('/player', {
    ...(poToken && { serviceIntegrityDimensions: { poToken } }),
    videoId,
    contentCheckOk: true,
    racyCheckOk: true,
    client,
    playbackContext: {
      contentPlaybackContext: { signatureTimestamp: yt.session.player?.signature_timestamp },
      ...(reloadPlaybackContext !== undefined && { reloadPlaybackContext }),
    },
  });
}

/** Why a playability status is a verdict on the track rather than on the client, or null if it isn't. */
const AGE_GATE = /confirm your age|age-restricted|inappropriate for some users|sign in to confirm/;
/**
 * "Sign in to confirm you're not a bot": about the visitor and their network,
 * not the track. Worth asking again signed in, never worth remembering as a
 * verdict on the track.
 */
const BOT_CHECK = /not a bot/;

/**
 * iOS app: when YouTube bot-checked VISIONOS for this visitor (typical on a
 * phone carrier's shared address), the next tracks go straight to the signed-in
 * session for a while instead of paying for the refused request each time.
 */
const BOT_CHECK_KEY = 'bitchord:ios:botcheck';
let botCheckedAt = Number(typeof localStorage === 'undefined' ? 0 : localStorage.getItem(BOT_CHECK_KEY) ?? 0);
// Hours: a carrier's address stays bot-checked, and every refused ask costs a second at start.
const BOT_CHECK_MEMORY_MS = 6 * 60 * 60_000;

export function preferSignedPlayback(): boolean {
  return isIOSApp() && Date.now() - botCheckedAt < BOT_CHECK_MEMORY_MS && ytAuthSnapshot().signedIn;
}

function permanentReason(status: string | undefined, reason: string | undefined, signedIn: boolean): string | null {
  const text = (reason ?? '').toLowerCase();
  if (BOT_CHECK.test(text)) return null;
  if (AGE_GATE.test(text)) {
    return signedIn
      ? 'YouTube won’t serve this age-restricted track to this account. Check the account’s age is verified on YouTube.'
      : 'This track is age-restricted. Sign in to YouTube Music in this browser to play it.';
  }
  if (/country|region/.test(text)) return 'This track isn’t available in your country';
  if (/private/.test(text)) return 'This track is private';
  if (/terminated/.test(text)) return 'The channel behind this track was terminated';
  if (/premium/.test(text)) return 'This track needs YouTube Music Premium';
  if (status === 'ERROR' && /removed|no longer available|does not exist/.test(text)) return 'This track was removed from YouTube';
  return null;
}

/**
 * Walks the clients until one answers OK. Each refusal is logged; if every
 * client refuses for a reason that is about the track, the verdict is
 * remembered so retries above this layer are answered without a request.
 *
 * @param skip clients the caller has already seen fail at the streaming stage.
 * @param signed [yt] is the signed-in instance (getSignedInnertube).
 */
/**
 * iOS app: the player responses already had, for an instant start (a replay,
 * or the next track prefetched while this one plays). googlevideo's URLs last
 * about six hours; two is well inside that.
 */
const RESPONSE_TTL_MS = 2 * 60 * 60_000;
const responses = new Map<string, { resolved: ResolvedPlayer; at: number }>();

export function forgetResponse(videoId: string, signed: boolean) {
  responses.delete(keyOf(videoId, signed));
}

export async function resolvePlayer(
  yt: Innertube,
  videoId: string,
  skip: ReadonlySet<PlayerClientName> = new Set(),
  signed = false,
): Promise<ResolvedPlayer> {
  const cached = isIOSApp() ? responses.get(keyOf(videoId, signed)) : undefined;
  if (cached && Date.now() - cached.at < RESPONSE_TTL_MS && !skip.has(cached.resolved.client) && cached.resolved.yt === yt) {
    trackLog.d(`${cached.resolved.client} answer reused (${Math.round((Date.now() - cached.at) / 1000)}s old)`, videoId);
    return cached.resolved;
  }
  const resolved = await resolveFresh(yt, videoId, skip, signed);
  if (isIOSApp()) {
    if (responses.size > 40) responses.delete(responses.keys().next().value!);
    responses.set(keyOf(videoId, signed), { resolved, at: Date.now() });
  }
  return resolved;
}

async function resolveFresh(
  yt: Innertube,
  videoId: string,
  skip: ReadonlySet<PlayerClientName>,
  signed: boolean,
): Promise<ResolvedPlayer> {
  const known = knownVerdict(videoId, signed);
  if (known) throw new UnplayableError(known.reason, known.ageGated);

  const { Utils, YT } = await import('youtubei.js/web');
  const candidates = clientsFor(videoId, signed).filter((c) => !skip.has(c)).slice(0, CLIENT_ATTEMPTS);
  let lastReason = 'No YouTube client would play this track';
  let permanent: string | null = null;
  let ageGated = false;
  let botChecked = false;

  for (const client of candidates) {
    const started = performance.now();
    try {
      let response = await playerRequest(yt, videoId, client, undefined, { signed });
      const info = new YT.VideoInfo([response], yt.actions, Utils.generateRandomString(16));
      const status = info.playability_status?.status;
      const ms = Math.round(performance.now() - started);
      const streaming = info.streaming_data;
      const playable = !!streaming?.server_abr_streaming_url || !!streaming?.adaptive_formats.some((f) => f.has_audio && !f.has_video);
      if (status === 'OK' && playable) {
        trackLog.d(`${client}${signed ? ' (signed in)' : ''} answered OK in ${ms}ms`, videoId);
        return { videoId, client, info, yt, signed };
      }
      const reason = info.playability_status?.reason ?? (status === 'OK' ? 'no audio stream in the response' : status ?? 'no status');
      lastReason = reason;
      const bot = BOT_CHECK.test(reason.toLowerCase());
      botChecked ||= bot;
      // iOS app: VISIONOS is the client that plays whole tracks. Bot-checked,
      // ask it once more carrying a player PO token (what a real client sends).
      if (bot && client === 'VISIONOS' && !signed && isIOSApp()) {
        const retried = await playerRequest(yt, videoId, client, undefined, { force: true }).catch(() => null);
        if (retried) {
          const again = new YT.VideoInfo([retried], yt.actions, Utils.generateRandomString(16));
          const againOk =
            again.playability_status?.status === 'OK' &&
            !!again.streaming_data?.adaptive_formats.some((f) => f.has_audio && !f.has_video);
          trackLog.i(`VISIONOS with a player PO token: ${againOk ? 'OK' : again.playability_status?.reason ?? again.playability_status?.status}`, videoId);
          if (againOk) return { videoId, client, info: again, yt, signed };
        }
      }
      // Still refused: don't fall through to the anonymous web clients (they
      // answer, but their streams stop at ~60-70 s): go signed in.
      if (bot && client === 'VISIONOS' && !signed && isIOSApp() && ytAuthSnapshot().signedIn) {
        botCheckedAt = Date.now();
        localStorage.setItem(BOT_CHECK_KEY, String(botCheckedAt));
        excludeClient(videoId, client, `${status}: ${reason} (${ms}ms); asking again signed in`, signed);
        throw new UnplayableError('YouTube asked to confirm this isn’t a bot; asking again signed in.', true);
      }
      const verdict = permanentReason(status, reason, signed);
      if (verdict) {
        permanent = verdict;
        ageGated ||= AGE_GATE.test(reason.toLowerCase());
      }
      excludeClient(videoId, client, `${status}: ${reason} (${ms}ms)`, signed);
    } catch (error) {
      // The bot-check hand-off above (iOS app) is meant for the engine.
      if (error instanceof UnplayableError) throw error;
      lastReason = String(error);
      excludeClient(videoId, client, `request failed: ${String(error)}`, signed);
    }
  }

  if (permanent) {
    rememberUnplayable(videoId, signed, permanent, ageGated);
    throw new UnplayableError(permanent, ageGated);
  }
  if (botChecked) {
    // Not remembered: the next tap asks again. Marked like an age gate so the
    // engine retries as the signed-in user, whom YouTube doesn't bot-check.
    throw new UnplayableError(
      signed
        ? 'YouTube asked to confirm this isn’t a bot. Try again in a moment.'
        : 'YouTube asked to confirm this isn’t a bot. Sign in to YouTube Music (menu ☰) and try again.',
      true,
    );
  }
  throw new Error(lastReason);
}
