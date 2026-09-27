# App Store screenshots

How the App Store Connect screenshots were made, so they can be redone after a UI change. Five
per device, 6.9" iPhone (1320×2868) and 13" iPad (2064×2752); App Store Connect scales these down
for every smaller device, so no other sizes are needed.

| # | iPhone | iPad |
|---|---|---|
| 1 | Timeline grid | Timeline grid |
| 2 | Search: "sunset by the sea" | same |
| 3 | Map over the Alps, grid filtered to it | Map over Iceland |
| 4 | Info sheet, scrolled to camera and location | Full-screen viewer (aurora photo) |
| 5 | Settings, signed in, backup on | Settings over the grid |

Everything is a real capture of the app. Only the frame, headline and caption are added.

## The pipeline

Steps 1, 2, 3 and 6 are scripts. Steps 4 and 5 are driving the simulator by hand, which is
where the time goes. Everything is written under `build/screenshots/`, which is gitignored,
except the finished screenshots. Those go in `fastlane/screenshots/en-AU/`, which is committed.

```bash
Tools/screenshots/fetch_photos.sh          # 1. ~100 MB of Unsplash photos -> build/screenshots/raw
swift Tools/screenshots/tag_photos.swift   # 2. EXIF dates, GPS, camera  -> build/screenshots/tagged
Tools/screenshots/setup_sims.sh            # 3. two dedicated simulators, ready to shoot
# 4-5. drive the app, save captures to build/screenshots/captures (below)
Tools/screenshots/compose_all.sh           # 6. frame + caption          -> fastlane/screenshots/en-AU
```

Build the app for the simulator first (AGENTS.md), with the CLIP models fetched. Without them
there is no search bar, and so no screenshot 2.

### 1–2. The photos

`photos.json` lists 85 Unsplash photos, grouped into invented trips so that every feature has
something to show:

- home in London (September)
- Tokyo and Kyoto (August)
- the Swiss Alps (July)
- Lisbon and the Algarve (June)
- Iceland (March)

Each photo has a date, time and GPS position. `tag_photos.swift` writes these into the EXIF data,
along with iPhone 17 Pro camera details. Search needs real image content. The timeline needs
dates, and the map needs coordinates. The simulator's own generated test media (`genmedia.swift`)
is flat coloured tiles and serves none of these.

- The Unsplash licence allows commercial use without attribution. **images.unsplash.com**
  accepts plain `curl`, but **unsplash.com** itself does not answer scripts with JSON. To find *new*
  photos, open unsplash.com in the browser and call its own search endpoint from the page
  (`fetch('/napi/search/photos?query=…&per_page=20')`). Drop results with `premium` or `plus`
  set, since those are not free. Record `urls.raw` without its query string as `unsplash`.
- The dates are fixed in 2026. The grid is grouped by month, so this doesn't matter much. If
  they look stale, shift the dates in `photos.json`: the newest trip is at the top of
  screenshot 1.
- **Time zones.** The simulator uses the host's zone. `simctl addmedia` treats an EXIF time
  with no offset as UTC, so every photo showed up shifted, with a 22:10 photo displayed at
  07:10 on an AEST host. The tagger therefore stamps the host's offset *for each photo's date*,
  which also gets daylight saving right.

### 3. The simulators

`setup_sims.sh` creates "Screenshots iPhone 17 Pro Max" and "Screenshots iPad Pro 13". If they
already exist, it **erases** them, so never point it at a simulator used for other work. It
then:

- installs the app, grants photo access and adds the tagged photos
- turns on dark mode, which makes the photos stand out, and month grouping
- sets 4 grid columns on the phone and 6 on the iPad
- pins the status bar to 9:41 with full battery

To start again from a clean library, re-run the script: `addmedia` has no undo, so it erases and
re-adds everything. The first launch starts search indexing. Give it a minute before searching.

### 4. Driving the app

Use `mcp__Claude_Code_iOS_Simulator__control`. Tap coordinates are in **points**: native pixels
÷ 3 on the phone (440×956) and ÷ 2 on the iPad (1032×1376).

**Pass `device` (the UDID) on every call.** Without it, the tool picks whichever booted
simulator it likes. It sent a tap and 17 typed characters to a different simulator this way.

**Take screenshots with simctl, never with the tool's `screenshot` action.** The tool's image
lagged several actions behind. It showed the grid while the app was already three screens
further on, which made working taps look like failures and prompted repeats.

```bash
xcrun simctl io <UDID> screenshot build/screenshots/captures/p_grid.png
```

Taps made during a transition animation are dropped. Wait a second or two after anything that
animates (opening a sheet, closing the map) before the next tap, then confirm with a fresh
capture.

The flow, with approximate phone points (iPad positions differ; measure them from a capture):

1. **Grid** (`p_grid`, `i_grid`): capture as launched.
2. **Search** (`p_search`, `i_search`): tap the search bar (phone: bottom, ≈ 200,903; iPad:
   top right) and type `sunset by the sea`. On the phone, tap the keyboard's Search key to
   dismiss the keyboard. The results are real on-device rankings; the top two rows are sunsets
   over the sea.
3. **Map** (`p_map`, `i_map`): close search with the X, then tap the map button (top right,
   ≈ 395,85). Pan with a `touch_path` drag and zoom with a two-finger `touch2_path` spread,
   until one trip fills the map and the grid below shows only its photos. That was the Alps
   (15 photos) on the phone and Iceland (13) on the iPad.
4. **Details** (`p_info`): tap a landscape photo in the map's grid, tap ⓘ, then swipe up inside
   the sheet. Capture when Camera and Location are showing and the filename is scrolled away.
5. **Viewer** (`i_viewer`, iPad only): open the tall aurora photo from the Iceland grid, which
   fills the iPad screen. On the iPad the info sheet covers the whole photo, which is why the
   iPad set has a viewer shot instead of a details shot.
6. **Backup** (`p_backup`, `i_backup`): see below.

### 5. The backup screenshot

This needs a signed-in server. Use the mock, with no synthetic assets (its coloured tiles would
join the grid), on Immich's real port, behind a friendly hostname:

```bash
python3 Tools/mock_immich.py --port 2283 --no-assets
```

```bash
dns-sd -P Photos _http._tcp local 2283 photos.local 127.0.0.1
```

`dns-sd` publishes `photos.local` → 127.0.0.1 over Bonjour for as long as it runs. It changes
no system configuration, and the simulator resolves the name. The address then reads
`photos.local:2283` rather than `127.0.0.1:4567`. Port 80 would drop the `:2283`, but a
non-root process cannot bind it here.

1. Settings (gear) → Connect to Immich. Enter `http://photos.local:2283`, then Continue.
2. Sign in with the mock's test account (`MOCK_EMAIL` / `MOCK_PASSWORD` in `mock_immich.py`).
3. At "Back Up This iPhone/iPad?", choose Start Backup. All photos upload to the mock within
   seconds.
4. Settings now shows the account, backup on and 0 waiting. Capture it.

Gotchas:

- **The Connect field remembers the last server,** even after sign-out and after deleting
  `immich.baseURL`. To clear it, long-press in the field, tap at the end of the text, then
  long-press ⌫ (≈ 406,798 on the phone) for about 3 seconds.
- **The backup prompt shows only on the first sign-in.** After that, the saved scope skips it.
- Stop `mock_immich.py` and `dns-sd` afterwards.

### 6. Framing

`compose_all.sh` holds the headlines and captions and runs `compose.swift` on each capture:

- the background is a navy gradient with faint biscuit shapes, taken from the app icon's palette
- the headline is two lines of SF Rounded Heavy, the second line in biscuit gold
- the capture sits in a dark device bezel at a fixed height, so the set lines up

Always review the output as a contact sheet. The problems that got fixed there were a caption
leaving a single word on its own line, and one device sitting higher than the rest because its
caption fit on one line.

The output is JPEG, about 9 MB for all ten, against 42 MB as PNG.

## Uploading

Commit `fastlane/screenshots/en-AU/`. The App Store workflow uploads the folder on every run,
**replacing** the screenshots in App Store Connect, so changes made in the web UI do not survive
a release. It orders them by filename, which is why the names are numbered. The App Store shows
the first three in search results, so the strongest features go first.

`en-AU` is the app's primary language. A folder named for a language the listing does not have
yet makes the workflow add that localization. That is the way to add a language, and also a way
to add one by accident.
