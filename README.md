# MJV Player (iOS, native Swift)

A native SwiftUI rewrite of the `mjvmediaplayer` web app: an offline music and video player for iPhone and iPad,
with YouTube / YouTube Music downloads.

## Features
- **Library:** songs, albums, artists, videos, playlists, favorites, recently added/played, most played, search, sort and filter.
- **Import:** from the Files app (files or whole folders), "Open in MJV Player" from other apps, and anything copied
  into *On My iPhone › MJV Player*. Reads tags (title, artist, album, genre, year, track number, embedded cover).
  A matching image file, or `cover.jpg` / `folder.jpg`, becomes the cover.
- **Covers:** missing song covers are found on iTunes automatically. You can also search covers or posters by hand,
  pick one from Photos, or use a frame from the video.
- **YouTube:** paste a link, or browse YouTube / YouTube Music inside the app (signed in with your account) and tap
  *Download this video*.
  - Music is saved as M4A (AAC) with title, artist, description and cover written into the file.
  - Video is saved as MP4 (H.264) up to 1080p. The silent HD stream and the audio are merged on the phone without re-encoding.
  - "Artist - Song (Official Video)" titles are cleaned up.
- **Now Playing:** large artwork over a blurred background, synced lyrics (LRCLIB) that scroll with the song and can
  be tapped to seek, queue (reorder, remove, play next / add to queue), shuffle, repeat one/all, speed 0.5–2×,
  sleep timer (minutes or end of track) with fade-out, AirPlay and a volume slider.
  - **Seeking:** drag the progress bar in Now Playing or in the mini player.
  - **Previous:** the first press restarts the song; pressing again within 4 seconds goes to the previous song.
  - **Artwork gestures:** double-tap the left or right side to jump 10 s, or the middle to favorite. Swipe for next/previous.
  - **A-B loop:** repeats a section of a song.
- **Sound:** 10-band equalizer with 23 presets and preamp, and crossfade between songs (0–12 s).
- **Video:** inline player with full screen and Picture in Picture. The sound keeps playing in the background.
- **Everywhere:** lock-screen, Control Center and car (CarPlay Now Playing / Bluetooth) controls with artwork.
  - Long videos and podcasts get ±15 s buttons on the lock screen.
  - Playback pauses when headphones are unplugged.
  - Long tracks and videos resume where you left off, and the queue is remembered after a restart.
- **CarPlay library browsing** is not included: it needs a CarPlay entitlement from Apple, which a sideloaded app
  signed with a personal Apple ID cannot have.

## Build
GitHub Actions (`.github/workflows/build.yml`) generates the Xcode project with XcodeGen (`project.yml`). It then builds an
unsigned `MJVPlayer.ipa` on macOS for every push to `main`. Download it from the run's *Artifacts* and install it with
Sideloadly, which signs it with your Apple ID. With a free Apple ID the app must be re-signed every 7 days.

YouTube extraction uses [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) (`main` branch, which follows YouTube's changes).
