# Lyrics

Private-use iOS app (a free clone of the App Store app "Lyricly"). It detects what's playing in
Apple Music or Spotify, fetches time-synced lyrics from LRCLIB, and shows the current line in a
Live Activity on the Lock Screen, in the Dynamic Island, and full screen in StandBy. Not intended
for the App Store: it relies on background tricks App Review would reject.

## Layout

- `project.yml` – XcodeGen spec. `Lyrics.xcodeproj` and both `Info.plist` files are generated and
  gitignored; edit `project.yml`, then run `xcodegen generate`.
- `Lyrics/` – app target (iOS 17+, SwiftUI, Observation, Swift 5 language mode).
  - `Engine/LyricsEngine.swift` – main loop: polls Apple Music (1 s) and Spotify (3 s), picks the
    source that is playing, loads lyrics, computes the current line every 200 ms, pushes Live
    Activity state.
  - `Engine/LiveActivityController.swift` – starts/updates/ends the activity, deduplicates states.
  - `Engine/BackgroundKeeper.swift` – silent `AVAudioEngine` loop (`.mixWithOthers`) that keeps the
    app alive in the background.
  - `Engine/LocationKeeper.swift` – coarse background location session; see "Gotchas".
  - `Engine/DiagnosticsLog.swift` – DEBUG-only log written to `Documents/diagnostics.log`.
  - `LyricsData/` – LRC parser and LRCLIB client.
  - `Playback/` – `Track`/`PlaybackSnapshot` models and the Apple Music source.
  - `Spotify/` – PKCE auth (tokens in Keychain) and the currently-playing client.
  - `Views/` – now-playing screen with scrolling lyrics, and Settings.
- `LyricsWidgets/` – widget extension with the Live Activity UI (Lock Screen, Dynamic Island, StandBy).
- `Shared/LyricsActivityAttributes.swift` – ActivityKit attributes, compiled into both targets.

## Build, install, debug

The Command Line Tools on this Mac are broken (their SDKs don't match their compiler). Always use Xcode's toolchain:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
D=00008130-0014081C0E9A001C   # the user's iPhone 15 Pro "reve"
xcodegen generate
xcodebuild -project Lyrics.xcodeproj -scheme Lyrics -destination "id=$D" \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device $D build/Build/Products/Debug-iphoneos/Lyrics.app
xcrun devicectl device process launch --device $D com.ramych.lyrics   # fails with "Locked" if the phone is locked; retry
```

- Signing: free personal team `YGT2F4663J` (set in `project.yml`). Builds expire after 7 days; reinstall.
- Screenshot the phone: `xcrun devicectl device capture screenshot --device $D --destination shot.png`.
- App diagnostics: `xcrun devicectl device copy from --device $D --domain-type appDataContainer
  --domain-identifier com.ramych.lyrics --source Documents/diagnostics.log --destination diag.log`.
- Crash reports: `--domain-type systemCrashLogs --source /`.
- The system log needs root. A sudoers rule (`/etc/sudoers.d/lyrics-logcollect`) allows it without a password, so run
 `sudo -n /usr/bin/log collect --device-udid $D --last 5m --output /tmp/lyricslogs/x.logarchive` yourself, then inspect it
  with `/usr/bin/log show` (plain `log` is a zsh builtin). Useful processes: `liveactivitiesd`, `SpringBoard`, `runningboardd`.
- Foundation-only code (`LyricsData/`, `Playback/Models.swift`) can be compiled and run on macOS with
  `xcrun swiftc -parse-as-library` plus a small `main.swift` to test against live LRCLIB.
- When checking whether the app is running with `devicectl device info processes`, note that lines are
  padded with trailing spaces; match `Lyrics.app/Lyrics\s*$`, not `$`.

## Gotchas (learned the hard way)

- **iOS rejects Live Activity updates from background apps that are "only playing background media".**
  `liveactivitiesd` logs `Process is only playing background media so is forbidden to update activity`.
  The fix is `LocationKeeper` (a coarse `CLBackgroundActivitySession`), which gives the app another background
  reason. Silent audio alone is not enough. Do not remove either keeper.
- **"Frozen" lyrics in StandBy after long sessions: iOS ends every Live Activity 8 hours after it starts.** The
 last content stays on screen for up to 4 more hours, so it looks frozen. Confirmed in the app log: an activity
 started at about 03:25 went `nil` at 11:25:41 while the app was in the background, and stayed gone until the
 app was opened at 12:30. `LiveActivityController` now replaces an ended activity (retrying from the background
 at most once a minute), starts a fresh one when the app is opened with an activity older than an hour, and
 ends replaced activities immediately. It logs each activity's state changes with its age.
- Live Activities are documented as startable only from the foreground; the controller adopts an existing
 activity after relaunch. Check the log (`activity request failed (background)` or `activity started from
 background`) to see whether a background start was accepted.
- **Reinstalling the app ends its Live Activity.** StandBy then falls back to Apple Music's player, and the
new activity appears only as a small icon until the user taps it. The user wants every working build
 installed right away without asking; relaunch the app afterwards. StandBy glitches right after an install are expected.
- **If the Live Activity never appears after an install, check for a stale widget registration.** Look in the
 system log: when `launchd` logs `Attempt to re-bootstrap service from different path, will use existing` for
 `com.ramych.lyrics.widgets`, followed by `No such file or directory` for the old bundle path, `chronod` is still
 pointing at the deleted install. `chronod` logs `Archive was nil` and StandBy shows nothing. Only a reboot
 fixes it: `xcrun devicectl device reboot --device $D`.
- **Lyrics sources:** Apple Music first, then LRCLIB. Synced lyrics from either beat plain text from the other.
 - Apple Music (`AppleMusicLyricsClient`) uses the private API behind music.apple.com:
 `amp-api.music.apple.com/v1/catalog/{storefront}/songs/{id}/lyrics` returns TTML (`TTMLParser`). It needs the
 user's `media-user-token` cookie, which is pasted into Settings and kept in the Keychain. The developer token
 is scraped from the web player's `index~*.js` bundle (the JWT with `iss: AMPWebPlay`) and cached until `exp`.
 The song ID is `MPMediaItem.playbackStoreID`; Spotify tracks are matched by catalog search on title and duration.
 Without the user token the lyrics endpoint returns 404.
 - LRCLIB alone missed about 16% of the user's plays, mostly Russian rap (Big Baby Tape, ROCKET, Тима Белорусских).
 Apple Music has synced lyrics for about 60% of those.
 - Musixmatch's unofficial desktop API is useless without an account: anonymous tokens get a decoy ("NOKIA" by
 Drake, gibberish text) for every song. NetEase works without a token but matches loosely; it has several SALUKI
 tracks that Apple lacks.
 - There's no public API for Apple Music lyrics (`MPMediaItem.lyrics` only covers local files), and Spotify's
 Web API has no lyrics.
- LRCLIB often files songs under a different title/artist split ("Song (feat. X)" by A vs "Song" by
  "A feat. X"). The client strips feat./remaster noise, tries a free-text search, and only settles for plain
  lyrics when no synced match exists within 5 s of the track duration. It retries once on HTTP 5xx.
- `MPMediaLibrary.authorizationStatus()` is an IPC call; it's cached in `AppleMusicSource`.
- Spotify needs a client ID from developer.spotify.com, entered in Settings; redirect URI `lyrics-app://spotify-callback`.

## StandBy layout (`LyricsLiveActivity.swift`)

- Detected with `@Environment(\.isActivityFullscreen)`. StandBy sizes the view to its content and centers it,
  so the StandBy view claims a fixed 160 pt height to keep the header pinned.
- `.contentMarginsDisabled()` on the configuration plus `.padding(.top, -10)` put the title/artist on the same
  row as the system icon StandBy draws at the top center. StandBy clips roughly 16 pt above the view, so
  going higher cuts off glyphs. A 48 pt gap in the middle of the header keeps text clear of that icon.
- Lyric lines are two plain `Text`s whose view tree is identical for every update (no `ViewThatFits`, no `if`,
 no `.id`/`.transition`), so a line change only swaps strings and cross-fades in place. Long lines shrink
 with `minimumScaleFactor` instead of truncating. Anything that swaps subtrees flashes black: `ViewThatFits`
 changing branch, or `.id(text)` + `.transition(.push)`.
- **Don't animate lines by identity.** A karaoke scroll (`ForEach` keyed by line index, so "next" animates into
 "current") froze the whole StandBy view, header included, for minutes. It froze with and without custom
 transitions. Signs in the system log: the app keeps updating, SpringBoard logs `Activity did update` for
 every update, and the widget renders each one, but the SpringBoard activity scene stops logging
 `Scene did receive new client settings`.
- The engine sends the Live Activity each line `liveActivityLead` (0.65 s) before it's sung, because updates take
 ~0.3 s to reach the screen. The in-app view uses the exact position.
- The user iterates on StandBy visually: take a screenshot after they tap the StandBy icon, rather than
  guessing offsets.

## StandBy track controls

- Live Activities get no gestures, and StandBy uses horizontal swipes itself. So the StandBy view has three
 invisible `Button(intent:)` zones instead: left third = previous, middle = play/pause, right = next.
- `LyricsWidgets/PlayerIntents.swift` holds plain `AppIntent`s that run in the widget extension and drive
 `MPMusicPlayerController.systemMusicPlayer`, then post a Darwin notification so the app polls immediately.
 Don't make it a `LiveActivityIntent`/`AudioPlaybackIntent`: those run in the app process, and iOS launches the
 app through the Shortcuts runner, which also asks for Face ID.
- **On a locked phone, StandBy always asks for Face ID before the first tap on any third-party widget or
 Live Activity.** SpringBoard's `AmbientAuthentication` does this before the intent is dispatched, and
 `authenticationPolicy` doesn't affect it. After one authentication, taps work for 10 minutes. This can't be
 worked around.
- Apple Music only. Spotify skipping would need Premium plus the `user-modify-playback-state` scope.

## Conventions

- Commit after each working change with a descriptive message.
- Keep diagnostics behind `DiagnosticsLog.write` (compiled out of release builds) instead of `print`.
