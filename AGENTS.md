# Lyrics

Private-use iOS app (a free clone of the App Store app "Lyricly"). It detects what's playing in
Apple Music or Spotify, fetches time-synced lyrics (Apple Music's own lyrics first, then LRCLIB), and
shows the current line in a Live Activity on the Lock Screen, in the Dynamic Island, and full screen in
StandBy. Not intended for the App Store: it relies on background tricks and private APIs that App Review
would reject.

## Status and open items (as of 28 Sep 2026)

- Everything below is committed on `main`. Remote: `gmonty:montyp0x/lyrics.git`. The agent can't push: the
 user's `~/.ssh/id_rsa` has a passphrase. Ask the user to run `git push`, or to run
 `ssh-add --apple-use-keychain ~/.ssh/id_rsa` once so the agent's shell can push.
- The installed build was made on 28 Sep with the free team, so it expires around 5 Oct. Reinstall before then.
- **Open: StandBy freezes with the karaoke scroll.** See "StandBy layout". The fixed two-line cross-fade layout
 is installed as the control. Nobody has confirmed yet that it never freezes over a full day. The user liked
 the karaoke scroll and wants smooth line changes without a black flash.
- **Untested live: the 8-hour expiry path** (`ResumeNotification`). The logic is in place, but no activity has
 reached 8 hours since it shipped. Check the log for `activity … state -> ended, age 8h00m` and
 `posted resume notification`.
- **Optional: NetEase as a third lyrics source.** It has synced lyrics for several SALUKI tracks that Apple
 Music and LRCLIB lack. Match on artist and duration, because its search matches loosely.
- **Old, unresolved: the first tap on the StandBy music icon sometimes exits StandBy.** It happened twice on
 25 Sep and wasn't reproduced after that.

## Layout

- `project.yml` – XcodeGen spec. `Lyrics.xcodeproj` and both `Info.plist` files are generated and
  gitignored; edit `project.yml`, then run `xcodegen generate`. That includes whenever you add a new source file.
- `Lyrics/` – app target (iOS 17+, SwiftUI, Observation, Swift 5 language mode).
  - `Engine/LyricsEngine.swift` – main loop: polls Apple Music (1 s) and Spotify (3 s), picks the playing
    source, looks up lyrics (`lookUpLyrics`), and computes the current line. The tick loop sleeps until the
    next line boundary (capped at 200 ms). It also gets the Apple Music user token (`connectAppleMusicLyrics`).
  - `Engine/LiveActivityController.swift` – starts, updates, and replaces the activity, handles the 8-hour
    expiry, and logs each activity's state changes and age.
  - `Engine/ResumeNotification.swift` – local "tap to bring lyrics back" notification.
  - `Engine/BackgroundKeeper.swift` – silent `AVAudioEngine` loop (`.mixWithOthers`) that keeps the
    app alive in the background.
  - `Engine/LocationKeeper.swift` – coarse background location session; see "Gotchas".
  - `Engine/DiagnosticsLog.swift` – DEBUG-only log in `Documents/diagnostics.log`. Lines look like
    `[28/09, 17:19:58,73 FG] …` (FG/BG/IN is the app state). It rotates to `diagnostics.old.log` at 2 MB.
  - `LyricsData/` – `LyricsLookup` result type, `LRCParser`, `LRCLibClient`, `AppleMusicLyricsClient`, `TTMLParser`.
  - `Playback/` – `Track`/`PlaybackSnapshot` models (`Track.appleMusicID` = catalog ID) and the Apple Music source.
  - `Spotify/` – PKCE auth (tokens in Keychain; `Keychain` helper is used app-wide) and the currently-playing client.
  - `Views/` – now-playing screen with scrolling lyrics, and Settings.
- `LyricsWidgets/` – widget extension: `LyricsLiveActivity.swift` (Lock Screen, Dynamic Island, StandBy UI)
  and `PlayerIntents.swift` (StandBy tap controls).
- `Shared/LyricsActivityAttributes.swift` – ActivityKit attributes, plus the Darwin notification name for
  player commands. Compiled into both targets.

## Build, install, debug

The Command Line Tools on this Mac are broken (their SDKs don't match their compiler). Always use Xcode's toolchain:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
D=00008130-0014081C0E9A001C   # the user's iPhone 15 Pro "reve", connected over USB only
xcodegen generate
xcodebuild -project Lyrics.xcodeproj -scheme Lyrics -destination "id=$D" \
  -derivedDataPath build -allowProvisioningUpdates build 2>&1 | rg -e "error:|BUILD SUCCEEDED|BUILD FAILED" | tee /tmp/b.txt
rg -q SUCCEEDED /tmp/b.txt || exit 1   # a pipe through rg hides a failed build; don't install the old one
xcrun devicectl device install app --device $D build/Build/Products/Debug-iphoneos/Lyrics.app
xcrun devicectl device process launch --device $D com.ramych.lyrics   # fails with "Locked" if the phone is locked; retry in a loop
```

- The user wants every working build installed and relaunched right away without asking.
- Signing: free personal team `YGT2F4663J` (set in `project.yml`). Builds expire after 7 days. The free
  team can't use APNs.
- App launch arguments need `--`: `devicectl device process launch --terminate-existing --device $D com.ramych.lyrics -- -flag`.
- Screenshot: `xcrun devicectl device capture screenshot --device $D --destination shot.png`. A 2556 px wide image
  is StandBy (landscape); a 1179 px wide one is the Lock Screen or home screen.
- App log: `xcrun devicectl device copy from --device $D --domain-type appDataContainer
  --domain-identifier com.ramych.lyrics --source Documents/diagnostics.log --destination diag.log`. Copy to a new
  path each time; an existing destination can silently leave the old file in place.
- Crash reports: `--domain-type systemCrashLogs --source /`.
- System log: a sudoers rule (`/etc/sudoers.d/lyrics-logcollect`) allows it without a password:
  `sudo -n /usr/bin/log collect --device-udid $D --last 5m --output /tmp/lyricslogs/x.logarchive`, then
  `/usr/bin/log show x.logarchive --style compact` (plain `log` is a zsh builtin). Useful processes: `liveactivitiesd`,
  `SpringBoard`, `chronod` (renders widgets), `LyricsWidgets`, `runningboardd`, `launchd`.
  - Limits: only Default level and above is collected; the Info/Debug messages from `chronod`/SpringBoard that
    would explain rendering decisions aren't. SpringBoard's messages are sometimes almost entirely missing (a few
    lines per minute), so "SpringBoard received nothing" may just mean nothing was logged. Once, the USB-C link
    flapped and the kernel logged about 330k lines in 5 minutes, which evicted everything else.
- Foundation-only code (`LyricsData/`, `Playback/Models.swift`) compiles on macOS with `xcrun swiftc -parse-as-library`
  plus a small `main.swift` wrapped in `@main struct`, which is handy for testing parsers and live APIs.
- When checking whether the app is running with `devicectl device info processes`, note that lines are
  padded with trailing spaces; match `Lyrics.app/Lyrics\s*$`, not `$`.

## Gotchas (learned the hard way)

- **iOS rejects Live Activity updates from background apps that are "only playing background media".**
  `liveactivitiesd` logs `Process is only playing background media so is forbidden to update activity`.
  The fix is `LocationKeeper` (a coarse `CLBackgroundActivitySession`), which gives the app another background
  reason. Silent audio alone is not enough. Do not remove either keeper.
- **"Frozen" lyrics after long sessions: iOS ends every Live Activity 8 hours after it starts.** The last
 content stays on screen for up to 4 more hours, so it looks frozen. Confirmed in the app log: an activity
 started at about 03:25 went `nil` at 11:25:41 while the app was in the background, and stayed gone until the
 app was opened at 12:30. `LiveActivityController` now ends an expired activity immediately, so no stale lyrics
 stay on screen, and posts `ResumeNotification`, whose tap reopens the app. It starts a fresh activity whenever
 the app is opened with one older than an hour, and ends replaced activities immediately.
- **Live Activities can only be started from the foreground.** Tested: `Activity.request` from the background
 fails with `visibility`, even with the silent-audio and location keepers running. Push-to-start would need
 APNs. The controller adopts an existing activity after relaunch.
- **Reinstalling the app ends its Live Activity.** StandBy then falls back to Apple Music's player, and the
 new activity appears only as a small icon until the user taps it. StandBy glitches right after an install are expected.
- **If the Live Activity never appears after an install, check for a stale widget registration.** When
 `launchd` logs `Attempt to re-bootstrap service from different path, will use existing` for
 `com.ramych.lyrics.widgets`, followed by `No such file or directory` for the old bundle path, `chronod` is still
 pointing at the deleted install. It logs `Archive was nil` and StandBy shows nothing. Only a reboot fixes it:
 `xcrun devicectl device reboot --device $D`, then the user enters the passcode.
- **iOS relaunches the app at boot, before the first unlock**, when `Documents` and the Keychain are still
 locked. `DiagnosticsLog` reopens its file lazily because of this.
- **Lyrics sources:** Apple Music first, then LRCLIB. Synced lyrics from either beat plain text from the other.
 - Apple Music (`AppleMusicLyricsClient`) uses the private API behind music.apple.com:
 `amp-api.music.apple.com/v1/catalog/{storefront}/songs/{id}/lyrics` returns TTML (`TTMLParser`). The developer
 token is scraped from the web player's `index~*.js` bundle (the JWT with `iss: AMPWebPlay`) and cached until
 `exp`. The user token comes from `SKCloudServiceController.requestUserToken(forDeveloperToken:)`, called with
 that scraped token. That's the Apple ID on the device, so no login is needed, and the lyrics endpoint accepts
 it (verified). It's fetched on first launch, from Settings → Reconnect, and automatically after a 401; it's
 kept in the Keychain. Pasting a `media-user-token` cookie by hand is still possible in Settings. For debug
 builds, `devicectl device process launch --terminate-existing … com.ramych.lyrics -- -connectAppleMusic`
 re-runs the device-token flow. The user's storefront is `tr`.
 The song ID is `MPMediaItem.playbackStoreID`; Spotify tracks are matched by catalog search on title and duration.
 Without the user token the lyrics endpoint returns 404.
 - LRCLIB alone missed about 16% of the user's plays, mostly Russian rap (Big Baby Tape, ROCKET, Тима Белорусских).
 Apple Music has synced lyrics for about 60% of those.
 - Musixmatch's unofficial desktop API is useless without an account: anonymous tokens get a decoy ("NOKIA" by
 Drake, gibberish text) for every song. Always check what a source actually matched, not just that it
 returned something. NetEase works without a token but matches loosely.
 - LRCLIB often files songs under a different title/artist split ("Song (feat. X)" by A vs "Song" by
 "A feat. X"). The client strips feat./remaster noise, tries a free-text search, and only settles for plain
 lyrics when no synced match exists within 5 s of the track duration. It retries once on HTTP 5xx.
- `MPMediaLibrary.authorizationStatus()` is an IPC call; it's cached in `AppleMusicSource`.
- Spotify needs a client ID from developer.spotify.com, entered in Settings; redirect URI `lyrics-app://spotify-callback`.

## Timing

- Apple Music's reported position matches our estimate to within 0.15 s (the drift is logged as `apple drift` when larger).
- A Live Activity update takes ~0.3 s to reach the screen: SpringBoard gets it within about 10 ms, and the widget
 extension then re-renders for about 270 ms. So the engine sends each line `liveActivityLead` (0.65 s) before
 it's sung; the user asked for that amount. The in-app view uses the exact position.
- The user-adjustable "Timing offset" in Settings is added on top.

## StandBy layout (`LyricsLiveActivity.swift`)

- Detected with `@Environment(\.isActivityFullscreen)`. StandBy sizes the view to its content and centers it,
  so the StandBy view claims a fixed 160 pt height to keep the header pinned.
- `.contentMarginsDisabled()` on the configuration plus `.padding(.top, -10)` put the title/artist on the same
  row as the system icon StandBy draws at the top center. StandBy clips roughly 16 pt above the view, so
  going higher cuts off glyphs. A 48 pt gap in the middle of the header keeps text clear of that icon.
- Lyric lines are two plain `Text`s whose view tree is identical for every update (no `ViewThatFits`, no `if`,
 no `.id`/`.transition`), so a line change only swaps strings and cross-fades in place. Long lines shrink
 with `minimumScaleFactor` instead of truncating.
- **Flashing black:** anything that swaps subtrees flashes black. That includes `ViewThatFits` changing branch
 (the original layout), and `.id(text)` + `.transition(.push)`.
- **Freezing with the karaoke scroll:** a `ForEach` keyed by line index, so that "next" animates into "current",
 looked good and ran fine for minutes. But all three observed StandBy freezes on 26 Sep happened with it
 installed, with and without custom transitions. It's in git history: commit `ef4bf10`, with
 `ContentState.lineIndex`. The mechanism isn't proven. In the one good log, the app kept updating, SpringBoard
 logged `Activity did update` for each update, and the widget rendered each one. But the SpringBoard activity
 scene stopped logging `Scene did receive new client settings`, so the screen kept the old frame. Treat
 identity-based animation as the prime suspect.
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

## Working with this user

- They test on the phone and report in short messages ("done", "froze again"). When they report a freeze or
 glitch, collect the system log and app log immediately, while the evidence is fresh.
- They want root causes, not guesses. Say plainly what's proven and what's only correlation.
- They listen mostly to Russian rap on Apple Music.

## Conventions

- Commit after each working change with a descriptive message.
- Keep diagnostics behind `DiagnosticsLog.write` (compiled out of release builds) instead of `print`.
- Never commit tokens. The Apple Music and Spotify tokens live in the Keychain only.
