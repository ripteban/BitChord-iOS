import { useEffect } from 'react';
import { useLocation, useNavigate } from 'react-router';
import { sizedArtwork } from '@/lib/artwork';
import { usePlayer } from '@/state/player';
import { useUi } from '@/state/ui';

type NativeHandler = { postMessage: (message: unknown) => Promise<unknown> };
type ChromeWindow = Window & {
  webkit?: { messageHandlers?: { bitchord?: NativeHandler } };
  __bitchordChrome?: (action: string, arg?: string) => void;
};

/**
 * The iOS app's native tab bar and mini player (ios/BitChord/NativeChrome.swift),
 * kept in step with the page: what's playing, where the user is, and whether
 * the full player or the drawer covers the screen. The bar's taps come back
 * through `window.__bitchordChrome`.
 */
export function NativeChromeBridge() {
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const nowPlaying = usePlayer((s) => s.nowPlaying);
  const status = usePlayer((s) => s.status);
  const hasNext = usePlayer((s) => s.index + 1 < s.queue.length || s.repeat !== 'off' || (s.autoplay && s.index >= 0));
  const fullScreen = useUi((s) => s.fullScreen);
  const drawerOpen = useUi((s) => s.drawerOpen);

  useEffect(() => {
    const w = window as ChromeWindow;
    w.__bitchordChrome = (action, arg) => {
      const ui = useUi.getState();
      const player = usePlayer.getState();
      switch (action) {
        case 'navigate':
          ui.setDrawerOpen(false);
          ui.setFullScreen(false);
          if (arg) navigate(arg);
          document.getElementById('scrollable-page')?.scrollTo({ top: 0 });
          break;
        case 'togglePlay':
          player.togglePlay();
          break;
        case 'next':
          player.next();
          break;
        case 'menu':
          ui.setFullScreen(false);
          ui.setDrawerOpen(true);
          break;
        case 'openPlayer':
          ui.setDrawerOpen(false);
          ui.setFullScreen(true);
          break;
      }
    };
    return () => {
      delete w.__bitchordChrome;
    };
  }, [navigate]);

  const title = nowPlaying?.title ?? null;
  const artist = nowPlaying?.artist ?? null;
  const artwork = nowPlaying?.artworkUrl ? sizedArtwork(nowPlaying.artworkUrl, 48) : null;
  const playing = status === 'playing' || status === 'buffering';
  const loading = status === 'loading';

  useEffect(() => {
    const handler = (window as ChromeWindow).webkit?.messageHandlers?.bitchord;
    void handler
      ?.postMessage({
        kind: 'chrome',
        path: pathname,
        fullScreen,
        drawerOpen,
        playing,
        loading,
        hasNext,
        nowPlaying: title !== null ? { title, artist, artwork } : null,
      })
      .catch(() => undefined);
  }, [pathname, fullScreen, drawerOpen, playing, loading, hasNext, title, artist, artwork]);

  return null;
}
