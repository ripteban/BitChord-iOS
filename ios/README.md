# BitChord for iOS

A native iOS shell around the BitChord web player (`web/app`). There is no iOS
build of the Android app; instead the web app runs in a `WKWebView`, and native
Swift code stands in for the browser extension:

| File | Role |
|---|---|
| `BitChord/inject.js` | Injected at document start: answers the page's bridge (relay transport), routes cross-origin requests through native code, ManagedMediaSource + AAC on iPhone |
| `BitChord/AppSchemeHandler.swift` | Serves the bundled web app on `app://bitchord/`, plus the streaming `/__net/` proxy |
| `BitChord/NetRules.swift` | The extension's header rules (`web/extension/lib/rules.ts`) in Swift |
| `BitChord/Bridge.swift` | The extension's background methods: `ping`, `yt.fetch`, `lyrics.*` |
| `devharness/server.mjs` | The same shim and bridge in Node, to test in a desktop browser at phone size |

Build: `.github/workflows/ios.yml` (macOS runner) builds `web/app`, copies it to
`ios/www`, runs `xcodegen`, smoke-tests on the simulator and produces an
unsigned `BitChord.ipa` to sideload (AltStore, SideStore, Sideloadly).

Not yet in the iOS app: YouTube Music sign-in, Spotify, Discord, offline downloads.
