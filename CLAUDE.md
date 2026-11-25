# Encore: project notes for Claude

## The user
- Talk to the user in Turkish. Write all code, UI text, commits and docs in English.
- They install the app on their own iPhone with **Sideloadly**, using a free Apple ID. The app must be re-signed every 7 days, and only 3 sideloaded apps are allowed at once.
- They have no Mac. Builds run only on GitHub Actions.
- They have YouTube Premium. Downloads are for their personal offline use.

## What it is
Encore is a native SwiftUI music and video player for iOS 16+ with YouTube / YouTube Music downloads.
- It began as a rewrite of the `mjvmediaplayer` web app and was first called **MJV Player**. It was renamed to Encore on 2026-11-25, at version 1.2.0.
- The repo is https://github.com/mihrapnidaapp/encore (public, branch `main`). The old name `mjv-player-ios` redirects to it.

## Do not change these (the user's library depends on them)
- **Bundle ID `com.mjv.player`.** Changing it would install a separate app with an empty library.
- **The data folder name `MJVPlayer`** in `Paths.support` (`Encore/Library.swift`), under Application Support.
  - It holds `library.json` and the `Artwork/` folder.
  - Media files are in `Documents/Media`. In the Files app that shows as *On My iPhone › Encore › Media*.
- **UserDefaults keys:**
  - player state: `pe.*`
  - equalizer: `eq.*`
  - settings: the `Prefs` keys, including `crossfade`

## Build and release
1. Push to `main`.
2. `.github/workflows/build.yml` runs on macos-15. It installs XcodeGen, generates the project from `project.yml`, builds without signing, and uploads the artifact `Encore-ipa` (containing `Encore.ipa`).
3. Watch the run with `LOG=/path/job.log bash tools/watch_build.sh <commit sha>`. It uses the git credential for github.com (user `mihrapnidaapp`).
4. Download the artifact with `GET /repos/mihrapnidaapp/encore/actions/artifacts/<id>/zip`. The ID is printed in the job log as "Artifact ID is N".
5. Save it as `dist/Encore-<version>.ipa`. `dist/` is git-ignored, and old MJV Player IPAs are in `dist/old-mjvplayer/`.
6. Before every release, bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
7. Aim for zero errors and zero warnings in the app's own files. The workflow prints warnings from `/Encore/`.

Things to know about the build:
- `macos-15` runners sometimes fail with "job was not acquired"; re-running the job fixes it.
- Swift language mode is 5.0, compiled with the Xcode 16 / Swift 6 toolchain. Keep `@MainActor` stores, and use `Task { @MainActor in }` inside `@Sendable` callbacks.
- The icon is generated with `python tools/make_icon.py Encore/Assets.xcassets/AppIcon.appiconset/icon-1024.png`. It draws a pink-to-orange play triangle with a white wave on an indigo-violet background.

## Code map (`Encore/`)
- **App.swift:** the app entry, `AppState` (tabs, sheets, toasts), the root `TabView` (Library, Search, YouTube, Settings), the mini player, and `GlobalPresenters`.
- **Library.swift:**
  - Models: `Paths`, `Prefs`, `Track`, `Playlist`, `Album`, `Artist`, `TrackSort`.
  - `LibraryStore`: JSON library, import, covers, lyrics.
- **Media.swift:**
  - Image tools and the artwork cache.
  - `MediaImporter`: reads tags and sidecar covers, imports folders.
  - `MediaExporter`: writes metadata, rewrites M4A, muxes video and audio to MP4 with AVAssetExportSession passthrough.
  - The LRC parser.
- **Online.swift:**
  - Online lookups: iTunes cover search, LRCLIB lyrics, YouTube oEmbed.
- **YouTube.swift:**
  - YouTubeKit (SPM, `branch: main`) is used with `[.local, .remote]` extraction.
  - When no MP4 video is found locally, it retries with `.remote` only.
  - Chunked 8 MB Range downloads, plus `DownloadManager`.
- **PlayerEngine.swift:** two `AVPlayer`s used for crossfade, where `player` is the audible one. It also handles:
  - **Ticking:** a 0.25 s timer.
  - **Seeking:** `position` / `duration` reads and seeks guarded by `seekTarget`.
  - **Previous:** restarts the song; a second press within 4 s goes to the previous song.
  - **Playback modes:** A-B loop, sleep timer, shuffle/repeat (`setRepeat`, `setShuffle`).
  - **System controls:** remote commands and Now Playing info.
- **Equalizer.swift:**
  - `EQParams`, a lock-protected value store read by the audio thread.
  - `EqualizerStore`, the UI model.
  - The `MTAudioProcessingTap` 10-band biquad EQ, attached through `item.audioMix`.
  - 23 presets, `EqualizerView` (which also holds the crossfade slider) and `VerticalSlider`.
- **NowPlaying.swift:**
  - `NowPlayingView`, with the backdrop placed in `.background` so the blurred image can't widen the layout.
  - `ScrubberView`: a custom drag bar driven by `TimelineView`; `compact` is the mini player version.
  - `VolumeRow` (MPVolumeView), lyrics, queue, `VideoSurface` (PiP, detaches in the background), the AirPlay button.
- **Components.swift:**
  - `Color.brand`, used instead of `accentColor` wherever `.tint(.white)` is applied.
  - Artwork and rows, track menus, `PlayShuffleButtons` (Play / Random).
  - `PlaybackModesBar`: labelled "Shuffle: On/Off" and "Repeat: Off/All/1 Song" pills.
  - `TracksView`.
- **LibraryViews.swift, YouTubeViews.swift, EditViews.swift:** the screens. `EditViews.swift` also holds Settings.

## History and status (as of 2026-11-25)
- 1.0.0: the first native release.
- 1.1.x:
  - The scrubber was rewritten, the previous-button behaviour fixed.
  - Added EQ, crossfade, A-B loop and volume.
  - Shuffle/repeat became labelled pills.
  - YouTube video got the remote fallback.
  - Fixed the Now Playing layout overflow.
- 1.2.0: renamed to Encore with the new icon.
- The user confirmed that 1.1.2 installs and works, and sent a screenshot that led to the layout fix.
- **Not yet confirmed on the device:**
  - whether the YouTube *video* button now appears (the card shows a grey "formats" summary line to help debug this)
  - the equalizer sound
  - crossfade
- **Not possible:** CarPlay library browsing, because sideloading with a personal Apple ID can't get the CarPlay entitlement. The car's Now Playing screen works.
- **Ideas offered but not built:** a "Add video from Photos" button (PHPicker).

The full earlier conversation is in this project's Claude session history (session `a3935297…`). It started in `klodtemp`, and its first part was about an unrelated Amazon refund case.
