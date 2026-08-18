# Working notes for agents on OnlyDaves

Product design lives in [DESIGN.md](DESIGN.md) — read it first; it is the source of truth for
architecture, milestones and the performance contract. This file is about *how to work on this
repo* and the mistakes already made here, so they are not repeated.

## Build, test, run

```bash
xcodebuild -project OnlyDaves.xcodeproj -scheme OnlyDaves -destination 'id=<SIM_UDID>' -derivedDataPath build/DerivedData build
```

```bash
xcodebuild test -project OnlyDaves.xcodeproj -scheme OnlyDaves -destination 'id=<SIM_UDID>' -derivedDataPath build/DerivedData
```

- Target the simulator by **UDID**, not name: several installed simulators share names like
  "iPhone 16 Pro" and `xcodebuild` fails with an ambiguous-destination error.
- `project.pbxproj` uses Xcode 16+ **filesystem-synchronized groups**. New `.swift` files under
  `OnlyDaves/` and `OnlyDavesTests/` are picked up automatically — do not hand-edit the project
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
     `xcrun simctl spawn <UDID> log show --last 60s --predicate 'subsystem BEGINSWITH "dev.onlydaves"' --style compact`).
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

Useful non-UI shortcuts:

```bash
xcrun simctl privacy <UDID> grant photos dev.onlydaves.app
xcrun simctl addmedia <UDID> *.jpg *.mov
xcrun simctl get_app_container <UDID> dev.onlydaves.app data   # inspect boot cache / prefs
```

## Test media

The simulator ships with only 6 stock photos and no videos, which is not enough to exercise
grouping, pinch columns or duration badges. Generate a richer library with
`Tools/genmedia.swift` (65 photos with EXIF capture dates, camera/lens/exposure and GPS, plus
three videos of 4s/23s/75s to cover `M:SS` and `H:MM:SS` formatting), then `simctl addmedia`
the output. Adding media while the app is running is also the quickest way to verify the
incremental timeline path (DESIGN.md D20).

## Conventions

- Swift Concurrency throughout; `actor` or `@MainActor` types, no Combine except where UIKit
  interop makes it trivial.
- Deviations from DESIGN.md are legitimate when the performance contract (§14) demands them,
  but must be recorded in the Implementation Log at the end of DESIGN.md with the reason.
- Comments explain constraints the code cannot show. Do not narrate what the next line does.
