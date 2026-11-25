/**
 * Mobile browsers can't install the extension, so they get the Android app
 * banner instead of the install prompt (prompt §1).
 */
export function isMobileBrowser(): boolean {
  const uaData = (navigator as Navigator & { userAgentData?: { mobile?: boolean } }).userAgentData;
  if (typeof uaData?.mobile === 'boolean') return uaData.mobile;
  return /Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent);
}

type IOSWindow = Window & { __bitchordIOS?: boolean; __bitchordNativeChrome?: boolean };

/** Running inside the iOS app (ios/BitChord/inject.js sets the flag before the page loads). */
export function isIOSApp(): boolean {
  return typeof window !== 'undefined' && (window as IOSWindow).__bitchordIOS === true;
}

/** The iOS app draws the tab bar and the mini player natively (Liquid Glass); the page hides its own. */
export function hasNativeChrome(): boolean {
  return typeof window !== 'undefined' && (window as IOSWindow).__bitchordNativeChrome === true;
}
