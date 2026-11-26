import { create } from 'zustand';
import { trackLog } from './trackLog';

/**
 * Tracks kept on the iPhone (iOS app): played from the file, at once and
 * without a network. Two kinds:
 * - cached: a track that played is saved in the background (temporary; iOS
 *   may clear it when space runs short), so playing it again starts at once;
 * - downloaded: kept for good, with the ⋯ menu's Download.
 *
 * The audio is fetched over SABR, the way it plays (googlevideo's SabrStream),
 * and handed to the app, which writes it to disk (OfflineStore.swift) and
 * serves it at app://bitchord/__local/<videoId>.
 */

export interface OfflineTrack {
  videoId: string;
  title: string;
  artist: string;
  album: string | null;
  artworkUrl: string | null;
  durationSec: number;
  permanent: boolean;
  bytes: number;
  savedAt: number;
}

export interface OfflineMeta {
  videoId: string;
  title: string;
  artist: string;
  album?: string | null;
  artworkUrl?: string | null;
  durationSec?: number | null;
}

type Native = { postMessage: (message: unknown) => Promise<unknown> };
type Reply<T> = { ok: true; result: T } | { ok: false; error: { message: string } };

function native(): Native | null {
  const w = window as Window & { __bitchordIOS?: boolean; webkit?: { messageHandlers?: { bitchord?: Native } } };
  return w.__bitchordIOS ? (w.webkit?.messageHandlers?.bitchord ?? null) : null;
}

async function call<T>(method: string, params: Record<string, unknown>): Promise<T> {
  const handler = native();
  if (!handler) throw new Error('offline storage is the iOS app’s');
  const reply = (await handler.postMessage({ kind: 'bridge', method, params })) as Reply<T>;
  if (!reply?.ok) throw new Error(reply?.error?.message ?? `${method} failed`);
  return reply.result;
}

interface OfflineState {
  tracks: Record<string, OfflineTrack>;
  /** videoId → 0..1 while a save runs. */
  saving: Record<string, number>;
}

export const useOffline = create<OfflineState>(() => ({ tracks: {}, saving: {} }));

export const offlineAvailable = () => native() !== null;

/** The saved file's URL for [videoId], or null. */
export function offlineUrl(videoId: string): string | null {
  return useOffline.getState().tracks[videoId] ? `${location.origin}/__local/${encodeURIComponent(videoId)}` : null;
}

export function offlineTrack(videoId: string): OfflineTrack | null {
  return useOffline.getState().tracks[videoId] ?? null;
}

export async function loadOffline(): Promise<void> {
  if (!offlineAvailable()) return;
  try {
    const list = await call<OfflineTrack[]>('ios.offlineList', {});
    useOffline.setState({ tracks: Object.fromEntries(list.map((t) => [t.videoId, t])) });
  } catch (error) {
    trackLog.w(`offline list failed: ${String(error)}`);
  }
}

const running = new Map<string, Promise<void>>();

/** Saves [meta]'s audio: kept for good when [permanent], else in the temporary cache. */
export function saveOffline(meta: OfflineMeta, permanent: boolean): Promise<void> {
  if (!offlineAvailable()) return Promise.resolve();
  const existing = offlineTrack(meta.videoId);
  if (existing && (existing.permanent || !permanent)) return Promise.resolve();
  if (existing && permanent) {
    return call<OfflineTrack>('ios.offlinePin', { videoId: meta.videoId }).then((track) => {
      useOffline.setState((s) => ({ tracks: { ...s.tracks, [track.videoId]: track } }));
    });
  }
  // The playing track is being captured as it streams: keep it for good when it completes.
  const playing = (window as Window & { __bitchordNowPlaying?: () => string | null }).__bitchordNowPlaying?.();
  if (playing === meta.videoId && !running.has(meta.videoId)) {
    keep.add(meta.videoId);
    useOffline.setState((s) => ({ saving: { ...s.saving, [meta.videoId]: 0.5 } }));
    return Promise.resolve();
  }
  const known = running.get(meta.videoId);
  if (known) return permanent ? known.then(() => saveOffline(meta, true)) : known;
  const job = download(meta, permanent)
    .catch((error: unknown) => {
      trackLog.w(`couldn't save for offline: ${error instanceof Error ? error.message : String(error)}`, meta.videoId);
      throw error;
    })
    .finally(() => {
    running.delete(meta.videoId);
    useOffline.setState((s) => {
      const saving = { ...s.saving };
      delete saving[meta.videoId];
      return { saving };
    });
  });
  running.set(meta.videoId, job);
  return job;
}

export async function removeOffline(videoId: string): Promise<void> {
  await call('ios.offlineDelete', { videoId });
  useOffline.setState((s) => {
    const tracks = { ...s.tracks };
    delete tracks[videoId];
    return { tracks };
  });
}

function toBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

async function download(meta: OfflineMeta, permanent: boolean): Promise<void> {
  const started = performance.now();
  const { videoId } = meta;
  useOffline.setState((s) => ({ saving: { ...s.saving, [videoId]: 0 } }));
  const { captureTrack } = await import('./youtube/engine');
  const { bytes, meta: found } = await captureTrack(videoId);
  await store(videoId, bytes, permanent, {
    title: meta.title || found.title,
    artist: meta.artist || found.author,
    album: meta.album ?? null,
    artworkUrl: meta.artworkUrl ?? found.thumbnail,
    durationSec: meta.durationSec || found.duration,
  });
  trackLog.i(
    `${permanent ? 'downloaded' : 'cached'} for offline: ${Math.round(bytes.byteLength / 1024)} KB in ${Math.round(performance.now() - started)}ms`,
    videoId,
  );
}

/** Tracks the user asked to keep (Download) while they were already being captured. */
const keep = new Set<string>();

async function store(
  videoId: string,
  bytes: Uint8Array,
  permanent: boolean,
  meta: { title: string; artist: string; album: string | null; artworkUrl: string | null; durationSec: number },
): Promise<void> {
  const saved = await call<OfflineTrack>('ios.offlineSave', {
    videoId,
    data: toBase64(bytes),
    permanent: permanent || keep.has(videoId),
    ...meta,
  });
  keep.delete(videoId);
  useOffline.setState((s) => {
    const saving = { ...s.saving };
    delete saving[videoId];
    return { tracks: { ...s.tracks, [videoId]: saved }, saving };
  });
}

/**
 * The playing track's audio, complete (the engine captured it as it streamed):
 * saved in the temporary cache, or for good if Download was asked meanwhile.
 */
export function storeCaptured(
  videoId: string,
  bytes: Uint8Array,
  meta: { title: string; author: string; duration: number; thumbnail: string | null },
): void {
  if (!offlineAvailable() || offlineTrack(videoId)) return;
  void store(videoId, bytes, false, {
    title: meta.title,
    artist: meta.author,
    album: null,
    artworkUrl: meta.thumbnail,
    durationSec: meta.duration,
  })
    .then(() => trackLog.i(`saved on the phone (${Math.round(bytes.byteLength / 1024)} KB): next time it starts at once`, videoId))
    .catch((error: unknown) => trackLog.w(`couldn't save the played track: ${String(error)}`, videoId));
}

void loadOffline();
// For the diagnostics and tests: the store from the console.
(window as Window & { __bitchordOffline?: unknown }).__bitchordOffline = { saveOffline, removeOffline, loadOffline };
