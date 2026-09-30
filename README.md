# CarPlay Lyrics

Live, time-synced lyrics for whatever is playing in Apple Music, shown as a Live Activity card on the CarPlay Dashboard, the iPhone Lock Screen and the Dynamic Island. Lyrics come from the free, community-run [LRCLIB](https://lrclib.net) database. No account, API key or server is needed.

This is a personal-use project. It keeps itself alive in the background with a silent audio loop and low-accuracy location updates, which App Review does not accept, so it is meant to be sideloaded with Xcode rather than published.

## What it does

- Follows the song Apple Music is playing (title, artist, album, position) and fetches synced lyrics for it.
- Shows the sung line and the upcoming line on one card, sized to fit the CarPlay Dashboard split view without truncation. Hindi and long English lines are laid out at one consistent font size.
- Keeps the card moving while the phone is locked and across song changes, so it can be started once before a drive.
- Prefers lyrics in English letters (including romanized Hindi and Punjabi), then Devanagari, then other scripts written out in English letters.
- Has an audio delay slider to compensate for Bluetooth and wireless CarPlay latency.
- Shows "Paused, open CarPlayLyrics to resume" if the app stops updating for 10 minutes, and removes the card after a long stretch with no music.
- Records background stalls and audio interruptions in a diagnostics list inside the app.

## Requirements

- Xcode 26 or newer, iOS 26 or newer on the phone.
- Apple Music (the Music app) as the player. Other players are not tracked.
- A free Apple ID is enough for signing. Free-team builds expire after 7 days and must be reinstalled.

## Setup

1. Open `CarPlayLyrics.xcodeproj` in Xcode.
2. Select the `CarPlayLyrics` target, then Signing & Capabilities, and pick your team. Do the same for the `LyricsWidgetExtension` target. Change the bundle identifiers if they clash with your team.
3. Connect the iPhone, pick it as the run destination and press Run.
4. On the phone, trust the developer certificate under Settings, General, VPN & Device Management.
5. Open the app and allow Media & Apple Music access and location access. Choose "Allow While Using App" or "Always". Location is only used to keep the app running; it is never stored or sent anywhere.
6. Make sure Live Activities are enabled for the app under Settings, CarPlayLyrics.

## Using it

1. Start playing a song in Apple Music.
2. Open CarPlay Lyrics once and tap "Start lyrics card". The card appears on the Lock Screen and, when connected to the car, on the CarPlay Dashboard.
3. Lock the phone. The card keeps updating on its own.
4. If the lyrics run ahead of or behind the singer, open the app and adjust the audio delay slider. The value is remembered.
5. Tap "Stop lyrics card" to remove the card. Otherwise it goes away by itself after 3 minutes with no song loaded, or 30 minutes paused when not connected to CarPlay.

## Testing in the Simulator

Turn on "Demo mode" in the app, or launch with the `-demo` argument. The app then plays a fake 44-second track with test lines in English and Hindi, so the card layout can be checked without Apple Music. Launching with `-simple` draws the card with plain text instead of the measured layout, as a diagnostic.

## How it works

| Part | File | Role |
|---|---|---|
| Tracker | `CarPlayLyrics/LyricsTracker.swift` | Polls the system music player, loads lyrics, picks the current line and updates the card. While locked, Apple Music stops reporting its position, so the tracker carries it forward from the last real reading. |
| Lyrics lookup | `CarPlayLyrics/LRCLibClient.swift` | Exact lookup by title, artist, album and length, then progressively looser searches. Results must match the song length. Ranks by script and retries network failures. |
| Live Activity | `CarPlayLyrics/LiveActivityController.swift` | Starts one Live Activity from the foreground and only updates it afterwards, spacing updates at least 2 seconds apart to avoid being throttled by iOS. |
| Keep-alive | `CarPlayLyrics/SilentAudioPlayer.swift`, `CarPlayLyrics/LocationKeepAlive.swift` | A silent, mixed-with-others audio loop and kilometer-accuracy location updates keep iOS from suspending the app while the phone is locked. |
| Card layout | `Shared/LyricsShared.swift` | The Live Activity model and card view, shared by the app and the widget extension so the in-app preview matches CarPlay exactly. Measures text with UIKit to choose one font size and balanced row breaks. |
| Widget | `LyricsWidgetExtension/LyricsWidget.swift` | The Live Activity configuration for the Lock Screen, Dynamic Island and CarPlay (`.small` activity family). |

`CarPlayLyrics-Info.plist` declares the `audio` and `location` background modes and opts into frequent Live Activity updates.

## Troubleshooting

- **Card says "Paused"**: the app stopped updating for 10 minutes. Open the app and check the Diagnostics section. A "FROZE" entry means iOS suspended the app; check that the app has location access and that Low Power Mode is off.
- **Lyrics stop when the phone locks**: try "Allow While Using App" for location if "Always" is set, or the other way round, and see which keeps the card moving.
- **"No synced lyrics for this song"**: LRCLIB has no timed lyrics for that recording. Coverage is community-driven.
- **Card never appears**: Live Activities are off for the app, or the app was started while the phone was locked. Start the card with the app open.

## License

MIT. See `LICENSE`.
