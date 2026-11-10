# Shotbolt for DynamicLake

A [DynamicLake](https://www.dynamiclake.com) plugin that puts [Shotbolt](https://shotbolt.app), a screenshot and screen
recording app for macOS, in the notch.

This repository holds the plugin only. The Shotbolt app is not open source; the plugin is a small separate program that talks
to it, and it does nothing without Shotbolt installed.

## What it does

- **While Shotbolt records**: a red dot and the time recorded in red; paused, DynamicLake's paused mark and the time frozen in
  white. Hover for the sneak peek with Pause/Resume and Stop (Cancel during a countdown). Saving and GIF conversion show as
  progress. When the take is saved the activity turns green for a few seconds ("Video saved · 1:05") with Copy.
- **The lake**:
  - Area, Window, Fullscreen and Record along the top, with More (Text, Scrolling, GIF and Self-Timer in the same row) and
    History. While a take runs, the take's row instead: what it is doing, its time, Pause/Resume and Stop.
  - The newest capture large: its picture, its title, a Keep star, "Video · 1:05 · 5 min ago", and Copy plus the two actions
    that capture is most used for (Annotate and Copy Text for a screenshot, Edit Video or Open and Show in Finder for a
    recording).
  - The other captures as a filmstrip. Right-click any capture for its actions; drag it into any app to drop the file.
- **DynaGlance**: the take's compact row while one runs, then the newest captures with Copy.
- **Show New Screenshots** (a setting, off by default): each new capture for a few seconds.

When Shotbolt is not installed, not running, too old for the plugin, or has "Let other apps control Shotbolt" off, the lake
says so with the one button that fixes it.

## Requirements

- macOS 14 or later, with DynamicLake.
- Shotbolt 1.2.4 or later, the first release with its status feed for companion apps; checked with Shotbolt 1.3.0. An older
  Shotbolt shows a notice asking for the update.
- "Let other apps control Shotbolt" on in Shotbolt's Settings (it is on by default). Shotbolt 1.3 has it under Workflows, Other
  apps; 1.2.4 and 1.2.5 under Advanced.
- The direct download of Shotbolt from shotbolt.app (or Homebrew). Shotbolt Lite from the App Store does not write the status feed,
  so the plugin does nothing with it.

On a display without a notch, DynamicLake Playground 1.2 draws only text in the compact live activity, so the red dot does not
show there. The time in red is what marks a recording on such a display.

## How it works

The plugin needs no permissions and makes no network requests. Everything stays on the Mac.

- **Reading**: Shotbolt writes `~/Library/Application Support/Shotbolt/Integrations/status.json` only while a companion asks
  for it. The plugin asks (a `nl.breukr.shotbolt.status-subscribe` notification) when it starts, every 4 minutes and whenever
  it finds no fresh file; Shotbolt deletes the file 10 minutes after the last ask, and posts `nl.breukr.shotbolt.status-changed`
  when it rewrites it. The file lists the 12 newest captures (path, size, length, title, the app it came from, the Keep star),
  the recording in progress and how the last one ended. `Tests/Fixtures/status-v1.json` is a sample. The plugin treats the
  file as untrusted: it ignores one over 1 MB, reads at most 50 captures, drops out-of-range numbers and dates, and reads
  thumbnails only from inside Shotbolt's own folder.
- **Running**: event-driven. It wakes for a message from DynamicLake, Shotbolt's notification, Shotbolt quitting, a change to
  its settings, and its own next deadline (for example a time like "5 min ago" that changes). While a take records it
  updates the time in the notch once a second. A safety check runs every 60 s.
- **Drawing**: the lake goes whole once, then as `lakePatch` commands for what changed, so the filmstrip keeps its scroll.
- **Acting**: buttons open `shotbolt://` links in the running Shotbolt without bringing anything forward, for example
  `shotbolt://capture-area`, `shotbolt://stop-recording` and `shotbolt://copy-capture?id=<capture id>`.
- **Thumbnails**: Shotbolt's own thumbnails, cropped square to 160 px, registered as DynamicLake image assets.
- **Log**: `~/Library/Logs/Shotbolt/DynamicLake.log`.

## Build and test

```sh
swift test                                  # the feed format, DynamicLake's documented limits, the planner and the loop
swift build && .build/debug/shotbolt-lake --check       # what the plugin sees of the installed Shotbolt
.build/debug/shotbolt-lake --demo-json      # every kind of command, one per line
scripts/package.sh                          # build/Shotbolt.dynamiclakeplugin and build/Shotbolt-<version>.zip (+ .sha256)
scripts/package.sh --sign "Developer ID Application: …"
```

For testing, install the `.dynamiclakeplugin` folder from DynamicLake's settings (Install Local).

## License

The code is under the MIT License (see `LICENSE`). The Shotbolt name and icon are trademarks of Breukr and are not covered by
that license.
