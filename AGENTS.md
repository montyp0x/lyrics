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
- The system log needs root, so ask the user to run
  `sudo log collect --device-udid $D --last 5m --output /tmp/lyricslogs/x.logarchive`, then inspect it
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
- Live Activities can only be *started* while the app is in the foreground; the controller adopts an
  existing activity after relaunch.
- **Reinstalling the app ends its Live Activity.** StandBy then falls back to Apple Music's player, and the
new activity appears only as a small icon until the user taps it. The user wants every working build
 installed right away without asking; relaunch the app afterwards. StandBy glitches right after an install are expected.
- Apple Music's own synced lyrics aren't accessible to third-party apps (no public API; `MPMediaItem.lyrics`
  only covers local files). Spotify's lyrics aren't in its Web API either. LRCLIB is the lyrics source.
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
- Lyric lines use `ViewThatFits` over a list of font sizes (largest first) so lines shrink instead of
  truncating with "…". Keep new text in the Live Activity following that pattern.
- The user iterates on StandBy visually: take a screenshot after they tap the StandBy icon, rather than
  guessing offsets.

## StandBy track controls

- Live Activities get no gestures (and StandBy owns horizontal swipes), so skipping uses invisible
 `Button(intent:)` zones over the left and right thirds; the middle third still opens the app.
- `Shared/SkipTrackIntent.swift` is a `LiveActivityIntent` compiled into both targets but performed in the
 app. The MediaPlayer code is behind `#if !WIDGET_EXTENSION` (flag set on the widget target in `project.yml`).
- Apple Music only. Spotify skipping would need Premium plus the `user-modify-playback-state` scope.

## Conventions

- Commit after each working change with a descriptive message.
- Keep diagnostics behind `DiagnosticsLog.write` (compiled out of release builds) instead of `print`.
