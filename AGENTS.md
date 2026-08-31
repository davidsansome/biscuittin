# Working notes for agents on Biscuit Tin

Product design lives in [DESIGN.md](DESIGN.md) — read it first; it is the source of truth for
architecture, milestones and the performance contract. This file is about *how to work on this
repo* and the mistakes already made here, so they are not repeated.

## Build, test, run

```bash
xcodebuild -project BiscuitTin.xcodeproj -scheme BiscuitTin -destination 'id=<SIM_UDID>' -derivedDataPath build/DerivedData build
```

```bash
xcodebuild test -project BiscuitTin.xcodeproj -scheme BiscuitTin -destination 'id=<SIM_UDID>' -derivedDataPath build/DerivedData
```

- Target the simulator by **UDID**, not name: several installed simulators share names like
  "iPhone 16 Pro" and `xcodebuild` fails with an ambiguous-destination error.
- `project.pbxproj` uses Xcode 16+ **filesystem-synchronized groups**. New `.swift` files under
  `BiscuitTin/` and `BiscuitTinTests/` are picked up automatically — do not hand-edit the project
  file to add sources.
- Running the test suite reinstalls the app and can reset its container, wiping `UserDefaults`
  and the boot cache. Expect grouping/column preferences to be back at defaults afterwards;
  that is not a persistence bug.

## Verifying UI: trust instruments, not your eyes

**The pitfall that cost the most time so far.** While building the M2 viewer, screenshots
appeared to show ghost toolbar icons (rotate/trash/info) duplicated at the top of the screen.
They did not exist. They were the **status bar's signal-dots, wi-fi and battery glyphs**, which
at the resolution screenshots are rendered back to the agent look almost exactly like the
toolbar's SF Symbols.

What made it expensive was not the misreading itself but ignoring better evidence:

- The **accessibility tree** already reported exactly one set of buttons, at y≈790.
- A **runtime frame log** already proved `toolbar frame=(0,728 402x146)` with buttons at y 56
  inside it — i.e. the layout was correct.

Both non-visual sources were right and were overruled by a visual impression, costing several
rebuild cycles and nearly landing a bogus `clipsToBounds` "fix" carrying a comment that
asserted a cause that had never been demonstrated.

**Rules that follow from this:**

1. A screenshot is evidence that something *looks* wrong. It is never sufficient evidence of
   *what* is wrong, and never sufficient to conclude something is wrong at all.
2. For anything geometric — position, size, overlap, duplication — get a non-visual reading
   before changing code:
   - `mcp__ios-simulator__ui_describe_all` / `ui_find_element` for the real view hierarchy and
     frames.
   - A temporary `Log.ui.error(...)` of the frames in question (`.debug` and `.info` are **not**
     persisted to the log store; read them back with
     `xcrun simctl spawn <UDID> log show --last 60s --predicate 'subsystem BEGINSWITH "dev.biscuittin"' --style compact`).
   - `Tools/pixelprobe.swift` to map the actual framebuffer — see below.
3. When an authoritative non-visual source contradicts your reading of an image, **the image
   reading is wrong**. Re-derive the mapping before doubting the instrument.
4. Never commit a fix whose comment states a cause you have not demonstrated. A confident
   comment on a speculative change is worse than no comment — it teaches the next reader
   something false.
5. Remove diagnostic logging before committing.

### Pixel probing

`Tools/pixelprobe.swift` renders a coarse ASCII map of a region of a PNG so framebuffer
contents can be read as data rather than interpreted visually:

```bash
xcrun simctl io <UDID> screenshot /tmp/shot.png
swift Tools/pixelprobe.swift /tmp/shot.png 0 200
```

It prints one row per 8 native pixels with the point coordinate alongside, so you can state
exactly what is present at a given y-position. Native screenshots are 3× the logical size
(1206×2622 for a 402×874 iPhone 17) — always convert before comparing against frames.

## Bugs that only a real run finds

Three defects in this repo were invisible to unit tests and would have shipped. All three were
caught by driving the app against `Tools/mock_immich.py` and watching what actually happened.

1. **`BGTaskScheduler.submit` for an unregistered identifier aborts the process.** It raises an
   *Objective-C* exception, which Swift's `try`/`catch` cannot intercept — so a `do/catch`
   around it looks safe and is not. Registration must happen before the app finishes launching,
   which is earlier than any SwiftUI scene exists, hence `BackgroundTaskRegistrar` +
   `AppDelegate`. Never submit unless registration succeeded.
2. **Swift's `hashValue` is seeded per process.** Using it for cache filenames meant the disk
   cache never survived a relaunch and silently re-downloaded everything. Any hash that persists
   across launches must be deterministic (`DiskCache.stableHash`).
3. **`Int("v3")` is nil.** The Immich version gate parsed the leading component of `"v3.1.0"` and
   rejected *every* real server as too old. Parse leading digits wherever they start.

A later run against a **real Immich server** found four more, including two that made whole
features non-functional: sign-in called an authenticated endpoint before obtaining a token, and
`duration` arrived as integer milliseconds rather than a string, which failed the entire sync
page and hid a 73-asset library.

The pattern: each one produced correct-looking code with no crash in tests, and failed only when
something outside the process (the OS scheduler, a relaunch, a real server string) was involved.
When a milestone integrates with something external, drive it for real before believing it.

**A mock you wrote yourself cannot falsify your own assumptions.** `Tools/mock_immich.py` spoke
this app's conventions — hex checksums, duration strings, unauthenticated `server/about` — so it
confirmed the client against itself and stayed green through every one of those bugs. It has
since been corrected to mirror the real server. When a mock and the real thing disagree, the
mock is wrong; fix it in the same change, or the next bug hides in the same place.

## Driving the simulator

Tap by **accessibility element**, not by arithmetic on a screenshot:

```
mcp__ios-simulator__ui_find_element  → returns the element's real AXFrame in points
mcp__ios-simulator__ui_tap           → tap that frame's centre
```

The same downscaling that produced the phantom icons also produced a mis-aimed tap early on:
computing a button's centre from screenshot pixels put the tap ~42pt low, which hit
"Don't Allow" on the photo-library permission prompt instead of "Allow Full Access", and the
resulting denied-access screen was briefly mistaken for an authorization bug.

**SwiftUI `Toggle` does not respond to synthetic taps** from these tools, even at coordinates
where a `Button` in the same form does. Verify toggle-gated behaviour by setting the underlying
default and relaunching:

```bash
xcrun simctl spawn <UDID> defaults write com.davidsansome.biscuittin "sync.enabled" -bool YES
```

Write it through `simctl spawn defaults`, not by editing the plist file — the simulator's
preference daemon caches and will overwrite a direct file edit on next launch.

Useful non-UI shortcuts:

```bash
xcrun simctl privacy <UDID> grant photos com.davidsansome.biscuittin
xcrun simctl addmedia <UDID> *.jpg *.mov
xcrun simctl get_app_container <UDID> com.davidsansome.biscuittin data   # boot cache / prefs
```

## Working on a physical device

The full deploy loop runs from here — no hands needed on the phone:

```bash
xcodebuild -project BiscuitTin.xcodeproj -scheme BiscuitTin -destination 'platform=iOS,id=<DEVICE_UDID>' -derivedDataPath build/DeviceDD -allowProvisioningUpdates build
```

```bash
xcrun devicectl device install app --device <DEVICE_UDID> build/DeviceDD/Build/Products/Debug-iphoneos/BiscuitTin.app
```

`xcrun devicectl list devices` gives the identifier; `xcrun xctrace list devices` gives the UDID
that `xcodebuild -destination` wants — they are different strings for the same phone.

**What cannot be done from here:** tapping the screen or taking live screenshots. The simulator
MCP tools are simulator-only. Either write an XCUITest that runs on the device, or have the user
tap and report.

**Reading device logs — the part that is not obvious.**
`xcrun devicectl device process launch --console` relays the process's stdout/stderr but **not**
os_log, so every `Logger` call is invisible there. `Log.device(_:_:)` exists for this: it writes
to os_log *and* mirrors to stderr in debug builds. Anything needed while debugging on real
hardware must go through it, or it will not reach the terminal.

`Tools/devrun.sh`-style capture: launch with `--console` redirected to a file, in the
background, and let the user tap at their own pace rather than racing a fixed window.

## Run the control before believing a negative

Concluding "the API refuses X" needs a control that isolates X. While investigating lossless
rotation, a rendition with an advanced EXIF orientation flag was rejected by PhotoKit, and the
first conclusion drawn was "PhotoKit rejects flag-only renditions". That was believed on one
observation. The control — running the *same* code path writing the source bytes verbatim, with
no orientation change — was accepted, which is what actually proved the flag was the cause
rather than a malformed file or a bad code path.

Cheap, decisive, and it would have been just as cheap before the conclusion as after. When a
result is negative, ask what single variable differs between it and a case that should succeed,
and run that case.

## Launch the bundle id you just built

The app's bundle id is **`com.davidsansome.biscuittin`**. It has been renamed more than once,
and a build under a superseded bundle id can still be sitting on the simulator; `simctl launch`
will happily start one, so you drive a stale binary while your new code sits unused. This cost
several cycles: the fix under test appeared not to work and produced no logs at all, because
the running app predated it.

Symptom to recognise: **no app logs whatsoever**, plus UI that ignores a change you know is in
the build. List every non-Apple bundle and look for one that is this app under a name nobody
remembers — which beats grepping for known-stale ids, because it also catches the next rename:

```bash
xcrun simctl listapps <UDID> | grep CFBundleIdentifier | grep -v com.apple
```

`Log.subsystem` is `dev.biscuittin.app` — the logging subsystem and the bundle id are
deliberately different strings; do not "fix" one to match the other. The corollary is that
every `simctl` subcommand above wants the **bundle id**, never the subsystem — a substitution
that survived undetected through a previous rename, because the subsystem reads like a bundle
id right up until the command silently does nothing.

## The simulator is not the device

Three bugs reached a real phone that the simulator structurally could not surface:

* **HEIC.** The simulator's stock library is JPEG, so a rotation's source container always
  matched the one PhotoKit requested. Real camera photos are HEIC, and iOS asks for a **JPG**
  rendition of them — encoding HEIC into that slot fails with `PHPhotosError.invalidResource`
  (3302). `renderedContentURL` is the authority on the container; never infer it from the input.
* **Photo library contents.** Generated test media has none of the shapes real photos do. A HEIC
  can be put into the simulator library with `simctl addmedia`, which is how the HEIC rendition
  path was finally verified without asking the user to hunt for the right photo.
* **Anything the user's own library gates**, such as iCloud-offloaded originals.

Run milestones that touch PhotoKit editing on hardware before believing them.

## Test media

The simulator ships with only 6 stock photos and no videos, which is not enough to exercise
grouping, pinch columns or duration badges. Generate a richer library with
`Tools/genmedia.swift` (65 photos with EXIF capture dates, camera/lens/exposure and GPS, plus
three videos of 4s/23s/75s to cover `M:SS` and `H:MM:SS` formatting), then `simctl addmedia`
the output. Adding media while the app is running is also the quickest way to verify the
incremental timeline path (DESIGN.md D20).

## Measuring a stall, not guessing at it

"It stalled for a few seconds" is a report about the **main thread**, and nothing else is evidence
for it. Chasing the sign-in stall (DESIGN.md) took four device runs, and the useful instruments
were these three — build them before forming a theory, not after:

1. **Timestamps.** `Log.device` stamps elapsed-since-process-start on every line, because
   `devicectl --console` supplies none. Without them a log cannot distinguish work that is *slow*
   from work that merely *happens later*, and every gap looks like a stall.
2. **A main-thread watchdog.** A background thread that pings `DispatchQueue.main` and reports
   how long the ping took to be serviced. This is the only direct measurement of "the UI froze";
   actor-side timings are not, however large they look. It falsified the first theory here — the
   worst block was 467 ms, not seconds.
3. **Phase breakdown, not totals.** `rebuildIndex took 394 ms` prompts guessing.
   `(remote 41, photokit 348, merge 5)` ends the argument: PhotoKit enumeration is ~88 % of it.

The first hypothesis — a per-page rebuild storm — turned out to be *real and worth fixing*, but it
was not what produced the several seconds the user described. Both facts came out of the same
capture. Instrument first; a plausible cause found by reading code is a hypothesis, not a finding.

**Watch for a direct call racing the `AsyncStream` that already reports the same event.** Sign-in
both awaited `fullSync` *and* called `timelineStore.refresh()`, while `fullSync` yields on the
change stream the store observes. The yield is delivered asynchronously, so it landed after the
refresh and triggered a second full rebuild. Two unordered sources for one event, not redundancy.
Remove diagnostic instrumentation before committing — but `Log.device`'s timestamp stays.

## A new log category is invisible on device until it goes through `Log.device`

Search indexing appeared not to run on a real phone: 90 seconds of console output
with nothing from the indexer. It had actually embedded the entire 2,721-asset
library in that window. The new `Log.search` category was writing to os_log, and
`devicectl --console` relays only stdout/stderr.

This file already said that about `Log.device` — the point worth adding is that
the rule applies to **every category you add later**, and that its failure mode is
not silence you notice but a *wrong conclusion you act on*: "the feature never
ran" instead of "I cannot see it". The confirming instrument was cheap and should
have come first — log the store's row count, not the absence of progress lines.

Absence of logging is never evidence of absence of work. Prove the negative with a
positive reading of state.

## Benchmarking anything lazily faulted: warm up, then alternate

Deciding whether photo coordinates could live on every `AssetStub` came down to
one question — does reading `PHAsset.location` during enumeration cost anything?
The first measurement said the variant *with* the extra property was 8× faster
than the control without it.

That is not a surprising result, it is an impossible one, and it should have been
read as a broken experiment rather than a finding. PhotoKit faults property values
on first touch, so whichever pass runs first pays for the whole library. The
control ran first and absorbed the cost.

Corrected shape: a warm-up pass over every property either branch will touch, then
run the branches in **both orders**, and report all four numbers plus the best of
each. The honest answer was 8 ms versus 6 ms — free, which is what unlocked the
design. Applies to anything with first-touch cost: Core Data faults, lazily
decoded images, memory-mapped files, a cold SQLite page cache.

**A result that is too good is a bug in the measurement.** Reach for the ordering
explanation before the flattering one.

## Conventions

- Swift Concurrency throughout; `actor` or `@MainActor` types, no Combine except where UIKit
  interop makes it trivial.
- Deviations from DESIGN.md are legitimate when the performance contract (§14) demands them,
  but must be recorded in the Implementation Log at the end of DESIGN.md with the reason.
- Comments explain constraints the code cannot show. Do not narrate what the next line does.
