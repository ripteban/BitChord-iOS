import { Settings, X } from 'lucide-react';
import { Component, useRef, type ReactNode } from 'react';
import { PrefetchNavLink } from '@/components/PrefetchLink';
import { ForwardIcon, PauseIcon, PlayIcon } from '@/components/icons/Transport';
import { HomeIcon, NewIcon, SearchIcon, type NavIconProps } from '@/components/icons/NavIcons';
import { sizedArtwork } from '@/lib/artwork';
import { usePlayer } from '@/state/player';
import { useUi } from '@/state/ui';

const TABS: { to: string; label: string; Icon: (props: NavIconProps) => React.ReactNode }[] = [
  { to: '/home', label: 'Home', Icon: HomeIcon },
  { to: '/new', label: 'New', Icon: NewIcon },
  { to: '/search', label: 'Search', Icon: SearchIcon },
  { to: '/settings', label: 'Settings', Icon: ({ size, className }) => <Settings size={size} className={className} strokeWidth={1.8} /> },
];

/**
 * Phone layout (below 484px): the mini player above a tab bar, as a native
 * music app has them. The desktop pill (PlayerBar) is hidden at this width;
 * tapping the mini player opens the full-screen player.
 */
export function MobilePlayer() {
  const nowPlaying = usePlayer((s) => s.nowPlaying);
  const playing = usePlayer((s) => s.status === 'playing' || s.status === 'buffering');
  const loading = usePlayer((s) => s.status === 'loading' || s.status === 'buffering');
  const hasNext = usePlayer((s) => s.index + 1 < s.queue.length || s.repeat !== 'off' || (s.autoplay && s.index >= 0));
  const { togglePlay, next } = usePlayer.getState();
  const setFullScreen = useUi((s) => s.setFullScreen);
  const setDrawerOpen = useUi((s) => s.setDrawerOpen);
  // Swipe up on the mini player opens the full player, as in Apple Music.
  const swiped = useRef(false);

  return (
    <div className="pointer-events-none absolute inset-x-0 bottom-0 z-[calc(var(--z-web-chrome)-1)] hidden flex-col max-sm:flex">
      {nowPlaying && (
        <div className="pointer-events-auto mx-2 mb-1.5">
          <div
            className="glass-pill flex h-(--mobile-mini-player-height) touch-none items-center gap-3 rounded-[14px] pr-2 pl-2"
            role="region"
            aria-label="Player"
            onPointerDown={(e) => {
              // The release may land outside the bar (a swipe ends above it): listen on the window.
              const startY = e.clientY;
              const id = e.pointerId;
              const end = (up: PointerEvent) => {
                if (up.pointerId !== id) return;
                window.removeEventListener('pointerup', end);
                window.removeEventListener('pointercancel', end);
                if (up.type === 'pointerup' && startY - up.clientY > 24) {
                  // Swallow the click this release may also produce.
                  swiped.current = true;
                  setTimeout(() => (swiped.current = false), 80);
                  setFullScreen(true);
                }
              };
              window.addEventListener('pointerup', end);
              window.addEventListener('pointercancel', end);
            }}
            onClick={(e) => {
              // Anywhere but the transport buttons opens the player.
              if (swiped.current) return void (swiped.current = false);
              if (!(e.target as HTMLElement).closest('[data-transport]')) setFullScreen(true);
            }}
          >
            <button
              className="flex min-w-0 flex-1 items-center gap-3 text-start"
              aria-label={`Now playing: ${nowPlaying.title}. Open the player`}
            >
              <span className="relative size-10 flex-none overflow-hidden rounded-[6px] bg-quinary">
                {nowPlaying.artworkUrl && (
                  <img className="size-full object-cover" src={sizedArtwork(nowPlaying.artworkUrl, 40)} alt="" draggable={false} />
                )}
              </span>
              <span className="flex min-w-0 flex-col">
                <span className="truncate type-[600_15px/20px] text-primary">{nowPlaying.title}</span>
                <span className="truncate type-[400_13px/17px] text-secondary">{loading ? 'Loading…' : nowPlaying.artist}</span>
              </span>
            </button>
            <button data-transport className="grid size-11 flex-none place-items-center text-primary" aria-label={playing ? 'Pause' : 'Play'} onClick={togglePlay}>
              {playing ? <PauseIcon size={30} /> : <PlayIcon size={30} />}
            </button>
            <button data-transport className="grid size-11 flex-none place-items-center text-primary disabled:opacity-40" disabled={!hasNext} aria-label="Next" onClick={next}>
              <ForwardIcon size={28} />
            </button>
          </div>
        </div>
      )}
      <nav
        className="pointer-events-auto grid grid-cols-4 glass-material pb-[env(safe-area-inset-bottom)] shadow-[0_-0.5px_0_var(--systemGray4,#0000001f)]"
        aria-label="Tabs"
      >
        {TABS.map(({ to, label, Icon }) => (
          <PrefetchNavLink
            key={to}
            to={to}
            onClick={() => setDrawerOpen(false)}
            className="group flex h-(--mobile-tab-bar-height) flex-col items-center justify-center gap-0.5 text-secondary aria-[current=page]:text-key"
          >
            <Icon size={26} className="text-current" />
            <span className="type-[500_10px/12px]">{label}</span>
          </PrefetchNavLink>
        ))}
      </nav>
    </div>
  );
}

/**
 * Around the full-screen player: if it fails to render on this device, say so
 * (with the reason) instead of leaving the tap with no visible effect.
 */
export class PlayerErrorBoundary extends Component<{ children: ReactNode; onClose: () => void }, { error: Error | null }> {
  override state = { error: null as Error | null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  override componentDidCatch(error: Error) {
    console.error('Full-screen player failed:', error);
  }

  override render() {
    const { error } = this.state;
    if (!error) return this.props.children;
    return (
      <div className="fixed inset-0 z-[calc(var(--z-contextual-menus)-2)] flex flex-col items-center justify-center gap-4 bg-[#1f1f1f] px-8 text-center text-primary">
        <p className="type-[600_17px/22px]">The player couldn’t open</p>
        <p className="type-[400_13px/18px] break-all text-secondary">{error.message}</p>
        <button
          className="grid size-11 place-items-center rounded-full bg-quinary"
          aria-label="Close"
          onClick={() => {
            this.setState({ error: null });
            this.props.onClose();
          }}
        >
          <X size={20} />
        </button>
      </div>
    );
  }
}
