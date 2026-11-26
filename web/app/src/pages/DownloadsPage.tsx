import { useMemo } from 'react';
import { PageHeader } from '@/components/PageHeader';
import { TrackList } from '@/components/music/TrackList';
import type { Track } from '@/data/music/types';
import { offlineAvailable, useOffline, type OfflineTrack } from '@/playback/offline';
import { seeAllTracks } from './pageStyles';

function asTrack(saved: OfflineTrack): Track {
  return {
    videoId: saved.videoId,
    title: saved.title,
    artists: saved.artist ? [{ name: saved.artist, id: null }] : [],
    album: saved.album ? { name: saved.album, id: null } : null,
    durationSec: saved.durationSec || null,
    explicit: false,
    thumbnail: saved.artworkUrl,
    index: null,
    plays: null,
  };
}

/**
 * iOS app: what's on the phone. Downloaded tracks (kept for good) first, then
 * the ones saved after playing (the temporary cache). All play offline.
 */
export default function DownloadsPage() {
  const tracks = useOffline((s) => s.tracks);
  const { downloaded, cached } = useMemo(() => {
    const all = Object.values(tracks).sort((a, b) => b.savedAt - a.savedAt);
    return { downloaded: all.filter((t) => t.permanent).map(asTrack), cached: all.filter((t) => !t.permanent).map(asTrack) };
  }, [tracks]);
  const megabytes = Math.round(Object.values(tracks).reduce((n, t) => n + t.bytes, 0) / (1024 * 1024));

  return (
    <div>
      <PageHeader title="Descargas" />
      <p className="mx-(--body-gutter) mt-1 type-callout text-secondary">
        {offlineAvailable()
          ? `${downloaded.length} descargadas · ${cached.length} guardadas al reproducir · ${megabytes} MB en el iPhone`
          : 'Las descargas son de la app de iPhone.'}
      </p>
      {downloaded.length > 0 && (
        <section className={seeAllTracks}>
          <h2 className="mx-(--body-gutter) mb-2 type-title-2-emphasized">Descargadas</h2>
          <TrackList tracks={downloaded} variant="playlist" source={{ title: 'Descargas', type: 'library', id: 'downloads' }} />
        </section>
      )}
      {cached.length > 0 && (
        <section className={seeAllTracks}>
          <h2 className="mx-(--body-gutter) mb-2 type-title-2-emphasized">Guardadas al reproducir</h2>
          <TrackList tracks={cached} variant="playlist" source={{ title: 'Guardadas', type: 'library', id: 'cached' }} />
        </section>
      )}
      {downloaded.length === 0 && cached.length === 0 && (
        <p className="mx-(--body-gutter) mt-6 type-body text-secondary">
          Toca ⋯ en cualquier canción y elige Descargar. Las que reproduces también se guardan solas.
        </p>
      )}
    </div>
  );
}
