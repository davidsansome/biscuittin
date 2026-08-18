# OnlyDaves — iOS Photo Browser: Design Document

**Status:** Draft v3 — adds the future-proofed rotation architecture (video/Live
Photo rotation in M9) and the performance & responsiveness contract. No code
written yet.
**Target:** Native iOS app (iOS 17+, iPhone-first, iPad-compatible layout).
**Working name:** `OnlyDaves` (from the repo name; trivial to rename).

---

## 1. Overview

OnlyDaves is a minimal native photo browser that presents a **single merged timeline** of:

- **Local photos and videos** from the device photo library (PhotoKit), and
- **Remote assets** from an optional, user-configured **Immich** server.

The app is fully usable offline and without an account. When an Immich account is
configured, remote assets appear in the same grid, and an optional **sync** feature
uploads local photos and videos to the server.

**Performance is a headline requirement, not a polish item** (see §14): the app
must start effectively instantly, new photos must appear immediately, and no user
interaction may ever wait on I/O or the network.

Core surfaces:

1. **Grid screen** — day/week/month-grouped thumbnail grid, newest first, pinch to
   change column count, long-press for multi-select, backup-status indicator.
   Videos appear as thumbnails with a duration badge.
2. **Viewer** — full-screen pager with swipe navigation, swipe-down dismissal, and a
   toggleable gradient toolbar (back / rotate L / rotate R / delete / info).
   Video pages play inline with AVPlayer.
3. **Info sheet** — metadata modal (date, camera, exposure, location map, file info,
   duration for videos).
4. **Settings** — Immich server URL + credentials, sync on/off, sync scope,
   account status.

---

## 2. Goals and Non-Goals

### Goals
- Instant startup, instant appearance of new photos, always-responsive UI (§14).
- Fast, smooth scrolling over very large libraries (100k+ assets).
- One unified timeline; an asset that exists both locally and on the server appears **once**.
- Offline-first: remote metadata and thumbnails are cached; the grid renders without network.
- Videos are first-class: shown in the grid, playable in the viewer, included in sync.
- Destructive/edit actions (rotate, delete) work on both local and remote assets.
  Rotation ships for images in v1 and for videos/Live Photos in M9 — the
  architecture supports all three from day one (D10).
- Reliable background upload sync with a visible "not backed up" count.

### Non-Goals (v1)
- Albums, favorites, search, people/faces, memories, shared libraries.
- Multi-account / multi-server support.
- Downloading remote originals for permanent offline storage (beyond caches).
- Any edits other than 90° rotation.
- Live Photo motion playback — Live Photos are displayed as still images in v1
  (they are tracked as a distinct media kind from day one, see D3, so motion
  playback and rotation can be added without model changes).

---

## 3. Critical Decisions

These are the load-bearing choices. Each is revisitable at review; everything
downstream assumes them as written.

| # | Decision | Choice | Rationale / Alternatives |
|---|----------|--------|--------------------------|
| **D1** | Minimum iOS version | **iOS 17.0** | Gives us modern Swift Concurrency and SwiftUI maturity, while covering the vast majority of devices. |
| **D2** | UI framework | **SwiftUI app shell; UIKit (`UICollectionView`, custom pager) for the grid and viewer**, bridged via `UIViewControllerRepresentable` | LazyVGrid degrades with 100k items, custom pinch-relayout, and custom transitions. UIKit compositional layout + diffable data source is the proven path. Settings/Info/simple chrome stay SwiftUI. |
| **D3** | Media types | **Images, videos, and Live Photos are distinct media kinds from day one** (`MediaKind` enum on every stub; Live Photo pairing tracked in the schema). All appear in the grid and sync in v1. Live Photos display/sync as stills in v1; videos play in the viewer. | Modeling the three kinds now (rather than a bool) is what lets M9 rotation and future Live Photo motion land without touching the domain model, DB schema, or timeline. |
| **D4** | Local persistence | **GRDB (SQLite) via SPM** for the remote-asset cache and sync state | We need fast bulk upserts (10k+ rows/sync page), date-bucket GROUP BY queries, and background-thread writes. GRDB is deterministic and testable. Alternative: SwiftData — simpler but weaker for bulk sync workloads and background writing. This is the app's only third-party dependency. |
| **D5** | Unified asset identity | Every displayed asset is an `Asset` with up to two **facets**: a local facet (PHAsset `localIdentifier`) and a remote facet (Immich asset UUID). Facets are linked by **SHA-1 checksum** (Immich's native checksum), with `(deviceId, deviceAssetId)` as a secondary match. | Checksum is the only identity Immich guarantees across upload paths. The link table is persisted so matching is done once, not per-launch. |
| **D6** | Timeline construction | **In-memory merged index** of lightweight `AssetStub` structs (~56 bytes each) sorted by capture date desc, bucketed on demand by day/week/month, published as immutable snapshots. Two additions for performance: **(a)** the index is **persisted as a boot cache** and loaded before anything else at launch (D19); **(b)** library/sync changes are applied **incrementally** to the index, not by full rebuild (D20) — full rebuild remains as the reconciliation fallback. | 200k stubs ≈ 12 MB — acceptable. If profiling shows problems at extreme sizes, the `TimelineStore` API is designed so a windowed implementation can replace the in-memory one without touching the UI. |
| **D7** | Immich auth | `POST /api/auth/login` with email + password → **access token stored in Keychain**. The password itself is never persisted. Requests use `Authorization: Bearer <token>`. | Matches requirement 13. An API-key field is a cheap future addition (`x-api-key` header) but is out of v1 scope. |
| **D8** | Immich API surface & versioning | Target **Immich v3.1.0** (current release, confirmed at review); require **server ≥ v3.0** via `GET /api/server/about` at login, failing settings validation with a clear message on older servers. | Implementers **must validate every endpoint path, field, and multipart shape against the v3.1.0 OpenAPI spec** — Immich serves it at `/api/docs` on the target server. The endpoint tables in §7 are the contract to verify, not a substitute for the spec. |
| **D9** | Remote metadata sync strategy | Initial **full sync** by paging `POST /api/search/metadata` (order desc, `withExif: true`, page size 1000) into SQLite; **delta sync** on foreground/app-start using `updatedAfter` cursor; deletions reconciled by a periodic full-ID sweep — v1 does the sweep weekly or on pull-to-refresh. | If v3.1.0's dedicated `/api/sync/*` delta endpoints prove stable during M5 implementation, they may be used instead — the choice is encapsulated behind `RemoteLibraryService` and changes nothing else. |
| **D10** | Rotation architecture | Rotation is a **per-facet physical operation dispatched by `MediaKind` to a per-kind strategy** behind one `AssetRotator` protocol. **v1 ships the image strategy**; the video and Live Photo strategies ship in **M9**, but their approach is decided now: **videos rotate losslessly** by rewriting the track transform (remux via `AVMutableMovie`, no re-encode) — locally written as a PhotoKit content-editing output, remotely as download → remux → `PUT /api/assets/{id}/original`; **Live Photos rotate via `PHLivePhotoEditingContext`** (keeps still + paired video consistent) locally, with the remote still replaced like an image. Images: local → PhotoKit content edit (Core Image re-encode); remote → download, rotate pixels, replace-original. Both facets are always updated; remote failure → partial-success toast + queued retry. Until M9, non-image rotations are skipped with a reported count. | Immich has no server-side rotate. Pixel rotation (images) keeps Immich thumbnails correct; transform-remux (video) avoids re-encoding multi-GB files and is lossless. The strategy protocol is the day-one commitment; per-kind implementations are additive. |
| **D11** | Delete semantics | The delete button (grid multi-select and viewer) **always deletes everywhere**: local facet via `PHAssetChangeRequest.deleteAssets` (iOS shows its own system confirmation) and remote facet via `DELETE /api/assets` (Immich moves to trash — recoverable server-side). Mixed-facet and remote-only deletes get **one app confirmation dialog** stating exactly what will happen. Local-only deletion is **never** offered through the delete button — it exists only as the separate "Free up space" feature (D18). | Confirmed at review: delete means delete, everywhere; freeing device space is a distinct, clearly-labeled operation. |
| **D12** | Upload sync mechanics | `BGProcessingTask` + **background `URLSession`** upload tasks; dedup before upload via `POST /api/assets/bulk-upload-check` with SHA-1 checksums; checksums computed streaming and cached in SQLite. Sync also runs opportunistically while the app is foregrounded. Videos upload through the same pipeline. | Background URLSession survives suspension; bulk-upload-check avoids re-uploading assets that already exist server-side (critical for first-run against an existing library). |
| **D13** | Thumbnail pipeline | One `ImageLoader` facade over two backends: `PHCachingImageManager` for local facets; URLSession + **two-tier cache (NSCache memory / disk LRU, ~500 MB cap)** for remote thumbnails (`size=thumbnail` for grid, `size=preview` for viewer, original only for rotation/zoom-in). Immich generates thumbnails for videos too, so the pipeline is media-kind-agnostic. No third-party image library. | Keeps dependencies to GRDB only; PhotoKit already is a cache for local. |
| **D14** | HTTP for self-hosted servers | Allow `http://` URLs via ATS exception **`NSAllowsLocalNetworking`** only; non-local plain-HTTP requires the user to acknowledge a warning and we add `NSAllowsArbitraryLoads` gated behind that (documented in settings UI). | Immich is commonly LAN-hosted without TLS. |
| **D15** | Photo library authorization | Request `.readWrite` full access on first launch of the grid. **Limited-library mode is supported read-only-ish**: grid shows the limited selection; sync and rotate of unselected assets obviously unavailable; a banner prompts to expand access. | Simplest correct handling of the iOS limited-photos picker. |
| **D16** | Concurrency model | Swift Concurrency throughout: stores and services are `actor`s or `@MainActor` classes; UI receives immutable snapshots via `AsyncStream`. No Combine except where UIKit interop makes it trivial. | One paradigm for implementing agents to follow. |
| **D17** | Sync scope | When the user signs in to Immich (or first enables sync), they choose between **"Sync all photos & videos"** and **"Sync new items only"**. "New only" anchors at the moment sync is enabled: only assets with `creationDate >= anchor` are queued. In Settings, the user can later **upgrade one-way** from "new only" to "all" (which simply clears the anchor and re-enumerates); there is no downgrade back to "new only". | Confirmed at review. One-way upgrade keeps the state model trivial — downgrading would raise unanswerable questions about already-uploaded assets. |
| **D18** | Free up space (later milestone) | A separate, explicit **"Free Up Space"** action (Settings row, milestone M8) deletes the **local copy only** of assets that verifiably exist on the server: `hasLocal && hasRemote`, checksum-linked, `backup_state = uploaded` (or server-confirmed duplicate). Shows candidate count + estimated reclaimable bytes, one confirmation, then a single batched PhotoKit delete (one system prompt). Never reachable through the delete button. | Confirmed at review as a distinct feature from delete. Checksum-verified linkage is the safety gate. |
| **D19** | Instant startup: boot cache + staged init | At `scenePhase` background (and after each index change, debounced), `TimelineStore` serializes its stub index + current grouping to a **compact binary boot cache** (single flat file, versioned header). At launch, the grid renders **from the boot cache before PhotoKit or GRDB are touched** — target first grid frame < 300 ms cold. PhotoKit authorization check, live re-index, delta sync, and `SyncEngine` all start **after** the first frame is committed, in that order of priority. Cache staleness is invisible: the live index reconciles via diffable-snapshot diff (cells fade in/out, scroll position preserved). A missing/corrupt/version-mismatched cache falls back to the normal path. | The single biggest startup cost is enumerating PhotoKit + querying SQLite before showing anything. Rendering yesterday's index instantly and reconciling quietly is how Photos-class apps feel instant. Flat file (not GRDB) so the read is one `mmap`-friendly sequential load with zero SQLite warm-up on the critical path. |
| **D20** | Responsiveness contract | Codified rules in §14 that all implementing agents must follow: incremental index updates (no full rebuild on the change path), optimistic mutations with rollback, zero awaits in gesture/tap handlers, zero synchronous I/O or image decode on the main thread, all network calls cancellable + off-main with the UI never blocked on them. | These are architectural obligations, not optimizations — several APIs below (e.g. `applyChange`, `ActionOutcome` rollback tokens) exist specifically to make the fast path the only path. |

---

## 4. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                            UI Layer                             │
│  GridViewController   ViewerPagerController   SwiftUI screens   │
│  (UIKit, bridged)     (UIKit, bridged)        (Settings, Info)  │
└──────────┬───────────────────┬──────────────────────┬───────────┘
           │ snapshots         │ page data / images   │ view models
┌──────────▼───────────────────▼──────────────────────▼───────────┐
│                        Domain Services                          │
│   TimelineStore ── BootCache   ImageLoader   PhotoActionService │
│   (merge+bucket)  (D19)        (thumb/full)  (rotate / delete)  │
│   VideoPlaybackProvider                                         │
│                        SyncEngine  ─── BackupStatusStore        │
└──────┬──────────────────────┬──────────────────────┬────────────┘
       │                      │                      │
┌──────▼────────┐   ┌─────────▼──────────┐   ┌───────▼─────────┐
│ LocalLibrary  │   │ RemoteLibrary      │   │ Persistence     │
│ Service       │   │ Service            │   │ (GRDB store)    │
│ (PhotoKit)    │   │ (ImmichClient +    │   │ remote_assets,  │
│               │   │  metadata cache)   │   │ facet_links,    │
│               │   │                    │   │ backup_state    │
└───────────────┘   └────────┬───────────┘   └─────────────────┘
                             │
                      ┌──────▼───────┐
                      │ ImmichClient │  (pure HTTP, no storage)
                      │ AuthSession  │  (Keychain token)
                      └──────────────┘
```

**Dependency rule:** UI → Domain Services → (LocalLibraryService | RemoteLibraryService | Persistence). Nothing below the domain layer imports UIKit/SwiftUI (AVFoundation is permitted in `VideoPlaybackProvider` and the M9 video rotator). `ImmichClient` is a dumb typed HTTP client with zero storage, trivially testable with a stubbed `URLProtocol`.

All services are created once in `AppEnvironment` (a plain composition-root class) and injected down — no singletons except the PhotoKit and URLSession system objects they wrap. **`AppEnvironment` construction must be near-free (D19): no I/O, no PhotoKit, no DB open in initializers** — every service opens its resources lazily on first use or in the post-first-frame startup sequence.

---

## 5. Project / Code Structure

Single Xcode app target plus a test target. SPM dependency: GRDB.

```
OnlyDaves/
├── App/
│   ├── OnlyDavesApp.swift          # @main SwiftUI App; owns AppEnvironment
│   ├── AppEnvironment.swift        # Composition root; zero-I/O init (D19)
│   ├── StartupSequencer.swift      # staged post-first-frame init order (D19)
│   └── RootView.swift              # Hosts GridScreen; injects environment
│
├── Domain/
│   ├── Models/
│   │   ├── Asset.swift             # Asset, AssetStub, AssetFacet, AssetID, MediaKind
│   │   ├── TimelineSnapshot.swift  # Snapshot, Bucket, Grouping enum
│   │   ├── AssetMetadata.swift     # Unified metadata for the Info sheet
│   │   └── BackupState.swift       # Per-asset backup status + counts
│   ├── TimelineStore.swift         # actor: merge, bucket, incremental apply, publish
│   ├── TimelineIndex.swift         # pure sorted-index value type (testable D20 invariant)
│   ├── BootCache.swift             # binary stub-index serialization (D19)
│   ├── ImageLoader.swift           # actor: unified thumb/full-image loading
│   ├── VideoPlaybackProvider.swift # AVPlayerItem for local or remote videos
│   ├── PhotoActionService.swift    # rotate/delete orchestration across facets
│   ├── Rotation/
│   │   ├── AssetRotator.swift      # protocol + MediaKind dispatch (D10)
│   │   ├── ImageRotator.swift      # v1: Core Image pixel rotation
│   │   ├── VideoRotator.swift      # M9: lossless AVMutableMovie transform remux
│   │   └── LivePhotoRotator.swift  # M9: PHLivePhotoEditingContext
│   └── MetadataService.swift       # builds AssetMetadata for Info sheet
│
├── Local/
│   ├── LocalLibraryService.swift   # PhotoKit fetch, change observation, auth
│   ├── PHAssetResolver.swift       # batched, bounded-LRU AssetStub → PHAsset lookup
│   ├── LocalAssetEditor.swift      # applies rotator output via PHContentEditing
│   └── LocalAssetExporter.swift    # original data + streaming SHA-1 for upload
│
├── Remote/
│   ├── ImmichClient.swift          # typed endpoints, auth header injection
│   ├── ImmichModels.swift          # Codable DTOs mirroring Immich OpenAPI (v3.1.0)
│   ├── ImmichAuthSession.swift     # login/logout, token in Keychain, /about check
│   ├── RemoteLibraryService.swift  # full/delta metadata sync into GRDB
│   └── RemoteThumbnailCache.swift  # disk LRU + NSCache for remote images
│
├── Persistence/
│   ├── AppDatabase.swift           # GRDB setup, migrations, lazy open
│   ├── RemoteAssetRecord.swift     # remote_assets table
│   ├── FacetLinkRecord.swift       # facet_links table (checksum joins)
│   └── BackupStateRecord.swift     # backup_state table + counters
│
├── Sync/
│   ├── SyncEngine.swift            # queue orchestration, scope, bg task scheduling
│   ├── UploadTask.swift            # one asset's upload lifecycle
│   ├── ChecksumStore.swift         # cached SHA-1 per local asset
│   └── BackupStatusStore.swift     # publishes "N not backed up" to UI
│
├── UI/
│   ├── Grid/
│   │   ├── GridScreen.swift            # SwiftUI wrapper + nav/toolbar/menu
│   │   ├── GridViewController.swift    # UICollectionView, diffable data source
│   │   ├── GridLayoutProvider.swift    # compositional layout; N columns
│   │   ├── PinchColumnsController.swift# pinch gesture → column count
│   │   ├── SelectionController.swift   # long-press multi-select state
│   │   ├── AssetCell.swift             # thumbnail cell (+selection badge, cloud glyph, video duration)
│   │   ├── BucketHeaderView.swift      # "Tue 12 Aug 2026" section header
│   │   └── SelectionToolbar.swift      # bottom bar in multi-select mode
│   ├── Viewer/
│   │   ├── ViewerScreen.swift          # UIViewControllerRepresentable wrapper
│   │   ├── ViewerPagerController.swift # horizontal paging between assets
│   │   ├── ZoomablePhotoView.swift     # per-page scroll/zoom image view (images)
│   │   ├── VideoPlayerPageView.swift   # per-page AVPlayerLayer view (videos)
│   │   ├── ViewerToolbar.swift         # gradient bottom bar (UIKit)
│   │   ├── ViewerTransition.swift      # zoom present + interactive swipe-down dismiss
│   │   └── ViewerState.swift           # current index, chrome visibility
│   ├── Info/
│   │   ├── InfoSheet.swift             # SwiftUI modal (map, camera, file rows)
│   │   └── InfoViewModel.swift
│   ├── Settings/
│   │   ├── SettingsScreen.swift        # SwiftUI form (incl. sync scope, M8 free-up-space)
│   │   └── SettingsViewModel.swift     # validate URL, login, sync toggle & scope
│   └── Shared/
│       ├── Toast.swift                 # transient error/partial-success notices
│       └── ConfirmationDialogs.swift
│
├── Support/
│   ├── Keychain.swift              # minimal Keychain wrapper
│   ├── DiskCache.swift             # generic LRU disk cache
│   ├── Signposts.swift             # os_signpost helpers for §14 budgets
│   └── Log.swift                   # os.Logger categories
│
└── OnlyDavesTests/
    ├── TimelineStoreTests.swift    # merge + bucketing + incremental apply
    ├── BootCacheTests.swift        # round-trip, corruption, version mismatch
    ├── ImmichClientTests.swift     # URLProtocol-stubbed endpoint tests
    ├── SyncEngineTests.swift       # dedup, retry, scope, state machine
    ├── ChecksumTests.swift
    └── Fixtures/                   # canned Immich JSON responses (v3.1.0 shapes)
```

---

## 6. Domain Model

### 6.1 Identity, media kinds, and facets

```swift
/// Stable app-level identity for one asset, regardless of where it lives.
/// Backed by whichever facet ID was seen first; stable across launches via facet_links.
struct AssetID: Hashable, Codable { let raw: String }

enum MediaKind: UInt8, Codable { case image, livePhoto, video }   // D3

enum AssetFacet: Hashable {
    case local(phLocalIdentifier: String)
    case remote(immichID: String)
}

/// Lightweight struct held in the in-memory timeline index (D6). Keep small —
/// it is also the boot-cache serialization unit (D19).
struct AssetStub: Hashable {
    let id: AssetID
    let captureDate: Date        // PHAsset.creationDate or Immich localDateTime
    let hasLocal: Bool
    let hasRemote: Bool
    let kind: MediaKind
    let durationSeconds: Float   // 0 for images / Live Photos
    let pixelWidth: Int32
    let pixelHeight: Int32
}

/// Fully resolved asset, materialized on demand (viewer, actions, info).
struct Asset {
    let id: AssetID
    let facets: [AssetFacet]     // 1 or 2 entries; local first if present
    let stub: AssetStub
}
```

`MediaKind` mapping — local: `PHAsset.mediaType` + `.mediaSubtypes.contains(.photoLive)`;
remote: `type` column + `live_photo_video_id IS NOT NULL`.

**Facet linking:** when `RemoteLibraryService` upserts a remote asset, and when
`ChecksumStore` computes a local asset's SHA-1, both write into `facet_links`
(`checksum → localIdentifier?, immichID?`). `TimelineStore` treats a linked pair as
one `AssetStub` with `hasLocal && hasRemote`. Secondary link: a remote asset whose
`(deviceId, deviceAssetId)` equals this device's ID + a local `localIdentifier`
(that's what our own uploads set, so our uploads link immediately without waiting
for a checksum pass).

### 6.2 Timeline

```swift
enum Grouping: String, CaseIterable { case day, week, month }

struct TimelineSnapshot {
    let grouping: Grouping
    let buckets: [Bucket]                 // ordered newest-first
    let totalCount: Int
    let provenance: Provenance            // .bootCache | .live  (grid may show a
                                          // subtle sync spinner while .bootCache)
    struct Bucket: Identifiable {
        let id: String                    // e.g. "2026-08-18", "2026-W33", "2026-08"
        let title: String                 // localized: "Today", "Aug 12–18", "August 2026"
        let items: [AssetStub]            // newest-first within bucket
    }
}
```

Snapshots are value types; the grid diffs them via `UICollectionViewDiffableDataSource<String, AssetID>`.

### 6.3 Metadata (Info sheet)

```swift
struct AssetMetadata {
    var fileName: String?
    var captureDate: Date?
    var pixelSize: CGSize?
    var fileSizeBytes: Int64?
    var durationSeconds: Double?         // videos only
    var cameraMake: String?, cameraModel: String?, lensModel: String?
    var fNumber: Double?, exposureSeconds: Double?, iso: Int?, focalLengthMM: Double?
    var location: CLLocationCoordinate2D?
    var placeName: String?               // reverse-geocoded (local) or Immich city/state
    var sources: [SourceBadge]           // "On this iPhone", "On Immich (server name)"
}
```

Local: `PHAsset` fields + EXIF from `PHContentEditingInput` → `CIImage.properties`
(for videos: `AVAsset` metadata). Remote: `exifInfo` from the cached Immich record.
If both facets exist, local wins per-field with remote filling gaps.

---

## 7. Immich Integration

### 7.1 `ImmichClient` (pure HTTP)

```swift
actor ImmichClient {
    init(baseURL: URL, tokenProvider: @Sendable () async -> String?)

    // Auth & server
    func login(email: String, password: String) async throws -> LoginResponse   // POST /api/auth/login
    func serverAbout() async throws -> ServerAbout                              // GET  /api/server/about
    func me() async throws -> UserDTO                                           // GET  /api/users/me

    // Metadata
    func searchAssets(_ req: MetadataSearchRequest) async throws -> SearchPage  // POST /api/search/metadata
    func assetInfo(id: String) async throws -> AssetResponseDTO                 // GET  /api/assets/{id}

    // Binary
    func thumbnailData(id: String, size: ThumbnailSize) async throws -> Data    // GET  /api/assets/{id}/thumbnail?size=
    func originalData(id: String) async throws -> (Data, filename: String)      // GET  /api/assets/{id}/original
    /// Authenticated streaming URL request for AVPlayer (see §10.1).
    func videoPlaybackRequest(id: String) throws -> URLRequest                  // GET  /api/assets/{id}/video/playback

    // Mutations
    func bulkUploadCheck(_ items: [(id: String, checksumHex: String)])
        async throws -> [UploadCheckResult]                                     // POST /api/assets/bulk-upload-check
    func makeUploadRequest(for upload: AssetUpload) throws -> (URLRequest, fileURL: URL)
        // POST /api/assets — multipart; returned request is handed to the
        // *background* URLSession by SyncEngine (client doesn't execute it)
    func replaceOriginal(id: String, fileURL: URL, upload: AssetUpload)
        async throws -> AssetResponseDTO                                        // PUT /api/assets/{id}/original
    func deleteAssets(ids: [String], force: Bool) async throws                  // DELETE /api/assets
}
```

Notes for implementers:
- All non-auth calls send `Authorization: Bearer <token>`; a 401 triggers a single
  token-refresh-by-relogin **prompt** (we don't store the password, so 401 →
  "Session expired, sign in again" state surfaced in Settings and a banner on the grid).
- Every method is `async`, runs on the actor (never the main thread), takes an
  implicit cancellation path (`Task.cancel`), and has an explicit `URLRequest`
  timeout (10 s metadata, 60 s binary). Callers must treat all of them as
  cancellable background work (§14 P5).
- Upload multipart fields: `assetData` (file part), `deviceAssetId`
  (= PHAsset localIdentifier), `deviceId` (stable per-install UUID),
  `fileCreatedAt`, `fileModifiedAt`, `filename`; header `x-immich-checksum: <sha1 hex>`.
  Response distinguishes `created` vs `duplicate` — both count as backed up.
  Same endpoint and fields for images and videos.
- **Validate every path/field against the v3.1.0 OpenAPI spec (D8) before
  implementation**; the spec is served by Immich itself at `/api/docs`.

### 7.2 `RemoteLibraryService` (sync of *metadata*, not files)

```swift
actor RemoteLibraryService {
    var isConfigured: Bool               // has base URL + token
    func fullSync() async throws         // page search/metadata → upsert remote_assets
    func deltaSync() async throws        // updatedAfter cursor
    func reconcileDeletions() async throws  // weekly / pull-to-refresh (D9)
    var changes: AsyncStream<RemoteChangeBatch>  // upserted/removed IDs → TimelineStore.applyChange
}
```

Runs delta sync on: app foreground (after first frame, per D19), settings save,
pull-to-refresh. Persists `last_sync_cursor` in the kv table. Change batches carry
the affected stub data so `TimelineStore` can apply them incrementally without
re-querying.

### 7.3 GRDB schema

```sql
CREATE TABLE remote_assets (
  immich_id TEXT PRIMARY KEY,
  checksum_hex TEXT NOT NULL,
  device_asset_id TEXT, device_id TEXT,
  type TEXT NOT NULL,                            -- IMAGE | VIDEO
  live_photo_video_id TEXT,                      -- non-null ⇒ Live Photo still (D3)
  duration_seconds REAL NOT NULL DEFAULT 0,
  file_name TEXT, capture_at REAL NOT NULL,      -- localDateTime as epoch
  width INTEGER, height INTEGER,
  is_trashed INTEGER NOT NULL DEFAULT 0,
  exif_json TEXT,                                -- raw exifInfo blob for Info sheet
  updated_at REAL NOT NULL
);
CREATE INDEX idx_remote_capture ON remote_assets(capture_at DESC);
CREATE INDEX idx_remote_checksum ON remote_assets(checksum_hex);

CREATE TABLE facet_links (
  checksum_hex TEXT PRIMARY KEY,
  local_identifier TEXT, immich_id TEXT
);
CREATE INDEX idx_links_local ON facet_links(local_identifier);

CREATE TABLE backup_state (
  local_identifier TEXT PRIMARY KEY,
  checksum_hex TEXT,
  state TEXT NOT NULL,        -- pending | uploading | uploaded | failed | ineligible | out_of_scope
  last_error TEXT, retry_count INTEGER NOT NULL DEFAULT 0,
  updated_at REAL NOT NULL
);

CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT);
-- keys: last_sync_cursor, device_id, sync_scope ("all" | "new_only"),
--       sync_scope_anchor (epoch; set when "new_only" chosen)
```

---

## 8. Local Library (PhotoKit)

```swift
@MainActor final class LocalLibraryService: NSObject, PHPhotoLibraryChangeObserver {
    var authorizationStatus: PHAuthorizationStatus
    func requestAccess() async -> PHAuthorizationStatus

    /// Images and videos (D3), sorted by creationDate desc. Returns lazy
    /// PHFetchResult; TimelineStore converts to AssetStubs off-main in batches.
    func fetchAllAssets() -> PHFetchResult<PHAsset>
    func asset(for localIdentifier: String) -> PHAsset?

    /// Emits PHChange objects. TimelineStore uses changeDetails(for:) to apply
    /// inserts/deletes/moves incrementally (D20) — new photos appear without
    /// a full re-enumeration.
    var changes: AsyncStream<PHChange>

    func delete(assets: [PHAsset]) async throws           // system confirmation appears
}

final class LocalAssetEditor {
    /// Applies a rotator's output (D10) via PHContentEditingInput/Output.
    /// adjustmentData: formatIdentifier "dev.onlydaves.rotate", version "1".
    func applyRotation(asset: PHAsset, clockwise: Bool, rotator: AssetRotator) async throws
}

final class LocalAssetExporter {
    /// Streams the primary PHAssetResource (photo or video) to a temp file,
    /// computing SHA-1 en route.
    func exportOriginal(asset: PHAsset) async throws -> (fileURL: URL, sha1Hex: String,
                                                         filename: String, created: Date?, modified: Date?)
}
```

### Rotation strategies (D10)

```swift
protocol AssetRotator {
    var supportedKind: MediaKind { get }
    /// Local side: produce the rotated rendition file for PHContentEditingOutput.
    func rotateLocal(input: PHContentEditingInput, clockwise: Bool) async throws -> URL
    /// Remote side: given the downloaded original, produce the replacement file.
    func rotateRemoteOriginal(fileURL: URL, clockwise: Bool) async throws -> URL
}
```

- **ImageRotator (v1):** Core Image `CGImagePropertyOrientation` transform,
  re-encode to the input's UTI (HEIC stays HEIC, JPEG stays JPEG, quality ≥ 0.9).
- **VideoRotator (M9):** lossless — open with `AVMutableMovie`, compose the 90°
  rotation into the video track's `preferredTransform`, write a remuxed copy
  (`writeHeader`/passthrough; no re-encode). Same file works for both the
  PhotoKit rendition and the Immich replacement, so multi-GB videos rotate in
  roughly file-copy time.
- **LivePhotoRotator (M9):** `PHLivePhotoEditingContext` with a frame processor
  applying the rotation — PhotoKit keeps the still and paired video consistent.
  Remote facet: the still is replaced like an image (the server-side paired video
  is refreshed by re-upload if the server copy has one; detail to confirm against
  the v3.1.0 spec during M9).

`PhotoActionService` dispatches by `stub.kind`; kinds with no registered rotator
(video/Live Photo until M9) are skipped and reported (see §11).

---

## 9. TimelineStore (the merge heart)

```swift
actor TimelineStore {
    init(local: LocalLibraryService, remoteDB: AppDatabase, bootCache: BootCache)

    /// UI subscribes once. First snapshot comes from the boot cache (D19),
    /// typically within ~100 ms of launch; subsequent snapshots are live.
    var snapshots: AsyncStream<TimelineSnapshot>

    func loadBootSnapshot() async                   // fast path; no PhotoKit/DB
    func startLive() async                          // full index build + observation (post-first-frame)

    func setGrouping(_ g: Grouping)                 // cheap: re-bucket existing index
    func applyChange(_ change: TimelineChange) async // incremental insert/remove/update (D20)
    func refresh() async                            // full re-index (reconciliation fallback)
    func asset(for id: AssetID) async -> Asset?     // materialize for viewer/actions
    func neighbors(of id: AssetID) async -> (prev: AssetID?, next: AssetID?)
}

/// Incremental mutations: from PHChange details, RemoteChangeBatch,
/// or optimistic UI (delete/rotate).
enum TimelineChange {
    case insert([AssetStub])
    case remove([AssetID])
    case update([AssetStub])          // e.g. facet gained/lost, rotation dims swap
}
```

**Full index build** (`startLive` / `refresh`, on the actor, off-main):
1. Enumerate `PHFetchResult` → stubs (`hasLocal = true`, `kind` per §6.1),
   collecting `localIdentifier`s.
2. Query `remote_assets WHERE is_trashed = 0` joined against `facet_links`:
   - linked to a seen local ID → mark that stub `hasRemote = true` (skip duplicate);
   - unlinked → new stub (`hasRemote = true` only).
3. Sort merged array by `captureDate` desc (PhotoKit result is pre-sorted; remote
   rows come sorted from SQL; do a linear merge, not a full re-sort).
4. Bucket per current `Grouping`; emit snapshot; write boot cache (debounced).

**Incremental path (the normal path, D20):** `PHChange` → `changeDetails(for:)`
inserts/removals/changes are converted to `TimelineChange` and applied by binary
search into the sorted index (O(log n) locate + O(k) splice) — a photo taken
while the app is open appears in the next runloop, not after a rebuild.
`RemoteChangeBatch` from delta sync applies the same way. Full `refresh()` runs
only on: authorization changes, reconciliation sweeps, or an incremental-apply
inconsistency (assert in debug, silent repair in release).

Boot cache writes: after each emitted snapshot, debounced 2 s, and on scene
background — serialization of 200k stubs is a single sequential write, ~10 MB.

---

## 10. Media Loading

### 10.1 ImageLoader and video playback

```swift
enum ImageVariant { case gridThumb(pointSize: CGSize, scale: CGFloat)  // grid cells
                    case viewerPreview                                  // ~screen size
                    case fullResolution }                               // zoom / rotate

actor ImageLoader {
    /// Yields progressively better images (e.g. degraded PhotoKit result, then final).
    /// For videos this returns poster/thumbnail images — playback is separate.
    func load(_ asset: AssetStub, variant: ImageVariant) -> AsyncStream<UIImage>
    func startPrefetch(_ stubs: [AssetStub], variant: ImageVariant)
    func cancelPrefetch(_ stubs: [AssetStub])
}

actor VideoPlaybackProvider {
    /// Local facet: PHImageManager.requestPlayerItem(forVideo:).
    /// Remote-only: AVURLAsset on the /video/playback endpoint, with the bearer
    /// token injected via AVURLAsset's HTTP header options.
    func playerItem(for asset: Asset) async throws -> AVPlayerItem
}
```

Routing: prefer the **local** facet when present (no network, PhotoKit cache).
Remote-only: `gridThumb` → `size=thumbnail`; `viewerPreview` → `size=preview`;
`fullResolution` → original download (also used by rotate). Immich serves
thumbnails for videos identically to images, so grid/viewer poster loading is
media-kind-agnostic. Remote responses go through `RemoteThumbnailCache` (memory
`NSCache` + `DiskCache` LRU keyed `immichID/variant`, 500 MB cap). The grid's
`UICollectionViewDataSourcePrefetching` calls map directly to
`startPrefetch`/`cancelPrefetch`; requests for cells that scroll off-screen are
cancelled (§14 P5). All decode happens inside the actor (ImageIO downsampling,
`kCGImageSourceThumbnailMaxPixelSize`); cells only ever receive ready-to-set
`UIImage`s.

---

## 11. PhotoActionService (rotate / delete)

Single entry point for both the viewer toolbar and multi-select toolbar; operates
on 1..n assets uniformly. **All mutations are optimistic (D20):** the timeline and
visible UI update immediately via `TimelineStore.applyChange`, the physical
operation runs in the background, and failures roll back with a toast.

```swift
struct ActionOutcome {
    let succeeded: [AssetID]
    let failures: [(AssetID, Error)]
    let skippedUnsupported: [AssetID]     // rotate: kinds with no rotator yet (D10)
}

actor PhotoActionService {
    func rotate(ids: [AssetID], clockwise: Bool) async -> ActionOutcome
    func delete(ids: [AssetID]) async -> ActionOutcome
    /// UI asks this first to decide which confirmation copy to show (D11).
    func deletePlan(ids: [AssetID]) async -> DeletePlan   // counts: localOnly/remoteOnly/both
    /// M8 (D18): candidates + byte estimate for "Free Up Space".
    func freeUpSpacePlan() async -> FreeUpSpacePlan
    func freeUpSpace(_ plan: FreeUpSpacePlan) async -> ActionOutcome
}
```

Per-asset rotate flow: dispatch to the `AssetRotator` for `stub.kind`; kinds
without a rotator (video/Live Photo until M9) go straight to
`skippedUnsupported` — the UI toast reads "N videos skipped" (copy updates in M9).
Local facet → `LocalAssetEditor.applyRotation` (checksum changes ⇒ `ChecksumStore`
invalidates; `backup_state` → `pending`; `facet_links` rewritten with the new
checksum). Remote facet → download original → `rotateRemoteOriginal` →
`replaceOriginal`. Batch operations run with limited concurrency (2–3) and report
per-asset outcomes. On completion: `applyChange(.update(...))` with swapped
dimensions + thumbnail cache invalidation for affected IDs.

Delete flow (D11 — always both facets): after confirmations, emit
`applyChange(.remove(ids))` immediately (tiles disappear now); then local
deletions in **one** `PHPhotoLibrary.performChanges` call (single system prompt
for the whole batch — shown *before* the optimistic removal, since the user can
cancel it) and remote deletions in one `deleteAssets` call. Failures re-insert
the affected stubs.

Free-up-space flow (D18, M8): plan = all assets with `hasLocal && hasRemote`,
checksum-linked, `backup_state ∈ {uploaded}` or confirmed duplicate; estimate
bytes from PHAssetResource sizes. Execution deletes **local facets only** in one
batched PhotoKit call; timeline stubs lose `hasLocal` via `applyChange(.update)`.

---

## 12. SyncEngine (upload backup)

States per local asset (in `backup_state`): `pending → uploading → uploaded`,
with `failed` (retry with exponential backoff, max 5 then park), `ineligible`
(e.g. iCloud-offloaded original unavailable and network-restricted), and
`out_of_scope` (excluded by the "new items only" scope — D17).

```swift
enum SyncScope: Equatable { case all
                            case newOnly(anchor: Date) }   // D17

actor SyncEngine {
    var isEnabled: Bool { get }                     // mirrors the settings toggle
    var scope: SyncScope { get }
    func setEnabled(_ on: Bool, scope: SyncScope?) async  // scope required on first enable
    func upgradeScopeToAll() async                  // one-way (D17): re-enumerates out_of_scope → pending
    func kick() async                               // evaluate queue now (foreground)
    func handleBackgroundTask(_ task: BGProcessingTask) async
    func handleBackgroundSessionEvents(identifier: String) async  // from AppDelegate hook
}

@MainActor final class BackupStatusStore: ObservableObject {
    @Published var remainingCount: Int              // grid indicator (req. 14)
    @Published var isActivelyUploading: Bool
}
```

Pipeline when enabled:
1. **Enumerate**: local assets (photos **and** videos) not `uploaded` in
   `backup_state` → ensure rows exist. Scope check (D17): under
   `.newOnly(anchor)`, assets with `creationDate < anchor` get `out_of_scope`;
   everything else `pending`. `upgradeScopeToAll()` flips all `out_of_scope` rows
   to `pending` and kicks the queue.
2. **Checksum**: compute missing SHA-1s (streaming, low-priority queue) → `ChecksumStore` + `facet_links`.
3. **Dedup**: batch `bulk-upload-check`; server-side duplicates → mark `uploaded`, link facets. This makes first-run against an already-populated Immich cheap.
4. **Upload**: for `accept`ed assets, export original to temp file, build multipart request, hand to the **background URLSession**; on completion (incl. `duplicate` response) → `uploaded`, upsert the returned remote asset into `remote_assets`, link facets. Videos ride the same path — background URLSession handles multi-GB files; temp exports are cleaned up on task completion and orphans swept at launch.
5. **Publish**: recompute `remainingCount` = local assets minus `uploaded`/`ineligible`/`out_of_scope`.

Scheduling: foreground kick on app-active (deferred behind first frame, D19) +
library change; `BGProcessingTaskRequest` (id `dev.onlydaves.sync`,
`requiresNetworkConnectivity = true`, external power not required) re-submitted
after each run. Wi-Fi-only is **not** a v1 setting (uploads respect Low Data Mode
via `allowsConstrainedNetworkAccess = false`). All engine work runs at
`.utility`/`.background` QoS — sync must never contend with scrolling.

The grid indicator (req. 14): a small pill in the nav bar — cloud icon + count when
`remainingCount > 0`, checkmark-cloud when 0 and sync enabled, hidden when sync
disabled. Tapping opens Settings. `out_of_scope` assets do **not** count as
"not backed up" — the user chose to exclude them.

---

## 13. UI Behavior Specs

### 13.1 Grid screen
- `UICollectionView` + compositional layout: `columns` items per row, square cells,
  2 pt gutters, section headers pinned = false. Diffable data source keyed by `AssetID`.
- **Grouping menu** (req. 3): nav-bar button → `UIMenu` (Day ✓ / Week / Month) →
  `TimelineStore.setGrouping`. Persisted in `UserDefaults`.
- **Pinch zoom** (req. 4): `UIPinchGestureRecognizer` on the collection view.
  `PinchColumnsController` accumulates scale; crossing ×1.3 thresholds steps
  `columns` within **1…8** (default 3). On step: build new layout, animate via
  `setCollectionViewLayout(_:animated:)`, keeping the cell nearest the pinch
  centroid stable (scroll compensation). Column count persisted.
- **Cell badges**: videos show a duration label ("0:42") bottom-right over a small
  gradient scrim; remote-only assets show a cloud glyph top-right; selection mode
  shows a check overlay.
- **Multi-select** (req. 11): long-press enters selection mode with the pressed
  cell selected; tap toggles membership; drag-select is out of scope. Nav bar shows
  "N selected" + Cancel; `SelectionToolbar` slides up with rotate L/R, delete
  (back/cancel exits mode). Rotate buttons stay enabled for mixed selections —
  unsupported kinds are skipped with a toast (D10); they disable only when the
  selection contains no rotatable assets. Actions call `PhotoActionService`;
  mode exits on completion.
- **Scroll performance budget**: cell configure must not decode on main; all decode
  in `ImageLoader`. Target: zero dropped frames at 120 Hz on recent hardware while
  flick-scrolling a cached region.

### 13.2 Viewer (reqs. 5–8)
- Presented full-screen with a custom **zoom transition** from the tapped cell
  (`ViewerTransition`). **The transition starts on the same runloop tick as the
  tap, using the already-decoded grid thumbnail as the placeholder** — the
  full-quality image upgrades in place when ready (§14 P4). Fallback if cell
  off-screen: crossfade.
- Horizontal paging across the **flattened timeline order** (bucket boundaries are
  invisible here). Pager keeps 3 live pages (prev/current/next). Image pages are
  `ZoomablePhotoView` (UIScrollView, min zoom aspect-fit, max 4×, double-tap to
  toggle); they show the grid thumbnail instantly, load `viewerPreview`, and
  upgrade to `fullResolution` when the user zooms past 1×. Neighbor pages
  prefetch their previews.
- **Video pages** (`VideoPlayerPageView`): show the poster frame instantly, attach
  an `AVPlayer` from `VideoPlaybackProvider`, and autoplay when the page becomes
  current; pause and reset when paged away. Center play/pause button appears with
  the chrome; a thin scrubber with elapsed/remaining time sits just above the
  toolbar (chrome-tied). Pinch zoom is disabled on video pages. Audio session
  category `.playback`, activated on first play. Player-item setup is async and
  never blocks the page swipe.
- **Swipe down to dismiss** (req. 6): pan gesture (only when at min zoom; videos
  pause on gesture start) drives an interactive dismissal — media tracks the
  finger with slight scale-down, background alpha follows progress; release past
  threshold/velocity → dismiss back into the grid cell (grid scrolls the target
  cell visible first if needed).
- **Chrome toggle** (req. 7): single tap toggles `ViewerToolbar` + status bar (and
  the video controls, when on a video page). The toolbar is a bottom overlay with
  a `CAGradientLayer` background — clear at top → ~55 % black at bottom — content
  inset for the home indicator.
- **Toolbar layout** (req. 8): `[ back ]  ···spacer···  [ rotate.left ] [ rotate.right ] [ trash ] [ info.circle ]`
  (SF Symbols, white, 44 pt targets). Rotate buttons are disabled (dimmed) on
  pages whose kind has no rotator yet (video/Live Photo until M9).
- Delete from viewer: after confirmation (per D11 — deletes locally **and** on the
  server), advance to the next asset, or dismiss if it was the last one.
- Rotate from viewer: optimistic UI — rotate the displayed image immediately with
  a short animation, then run the real edit; on failure, revert + toast.

### 13.3 Info sheet (req. 9)
SwiftUI `.sheet` with medium/large detents. Sections: **File** (filename, date/time,
resolution, size, duration for videos), **Camera** (make/model/lens, ƒ, shutter,
ISO, focal length — section hidden if empty), **Location** (non-interactive `Map` +
place name; hidden if none), **Availability** (source badges + backup state). Data
from `MetadataService`; the sheet opens immediately with whatever is cached and
fills rows in as slower sources (content-editing input EXIF, `assetInfo(id:)`
refresh) resolve — it never waits on I/O to present.

### 13.4 Settings (req. 13)
SwiftUI form:
- **Server**: URL field (validated: scheme+host; http triggers D14 warning), email,
  password (`SecureField`), Sign In / Sign Out button, status row (server version,
  user email when connected, "session expired" state).
- Sign-in flow: `serverAbout` version gate (D8, ≥ v3.0) → `login` → store token
  (Keychain) + base URL (`UserDefaults`) → trigger initial `fullSync` with
  progress row → **sync scope prompt** (D17): "Back up all photos & videos" vs
  "Back up new items only" (also offers "Not now", which leaves sync off).
  Sign-in runs as a cancellable background task with inline progress; the rest of
  the app stays fully usable during the initial full sync.
- **Sync**: toggle (req. 14) — first enable without a chosen scope re-asks the
  scope question. Below the toggle: a scope row showing "All items" or
  "New items only (since 18 Aug 2026)" with an **Upgrade to all items** button
  (one-way, D17, with a confirmation stating roughly how many older items will be
  queued). Shows remaining count + last-sync time.
- **Free Up Space** (M8, D18): row showing reclaimable estimate ("12.4 GB in 3,412
  items backed up to Immich"); tap → confirmation → batched local delete.
- Sign Out: clears token, keeps cached metadata/thumbnails (still browsable
  offline-read-only), disables sync. A separate "Remove server data" button wipes
  the remote cache tables + thumbnail disk cache.

---

## 14. Performance & Responsiveness Contract (D19, D20)

Non-negotiable rules for every implementing agent. PR-blocking, not aspirational.

- **P1 — Instant startup.** First grid frame < 300 ms cold launch on mid-range
  hardware. The launch path is: render boot-cache snapshot (D19) → first frame →
  `StartupSequencer` then starts, in order: PhotoKit auth check + live index,
  delta sync, `SyncEngine`. Nothing heavier than reading the boot-cache file may
  run before the first frame; `AppEnvironment` init performs zero I/O.
- **P2 — New photos appear instantly.** Library and sync changes flow through
  `TimelineStore.applyChange` (incremental splice), never a full rebuild. A photo
  captured while the app is open must be visible in the grid within one second,
  perceived as immediate. Full `refresh()` is reserved for reconciliation.
- **P3 — The main thread never blocks.** No synchronous disk I/O, DB access,
  checksum, or image decode on the main thread — ever. All decoding happens in
  `ImageLoader` with pre-downsampled output. Watchdog: os_signpost intervals
  around snapshot apply, cell configure, and transition start; any main-thread
  hang > 250 ms in Instruments is a bug.
- **P4 — Every interaction responds on the same runloop tick.** Tap, pinch, swipe,
  and button handlers contain **no `await` before their first visible effect**.
  Where the real work is slow, show the effect optimistically (§11) or show the
  cached/placeholder rendition immediately (viewer transition, info sheet) and
  upgrade in place. Rollback + toast on failure, never a spinner-first flow.
- **P5 — Network is always background, always cancellable.** All requests run off
  the main actor with explicit timeouts; scroll-away cancels image requests;
  page-away cancels preview/original loads; leaving settings cancels validation.
  No user-visible UI state may be *gated* on a network response except where the
  data literally is the feature (sign-in result, remote-only original) — and
  those show progress inline while the rest of the app stays interactive.
- **P6 — Background work yields to the UI.** Sync, checksumming, boot-cache
  writes, and reconciliation run at `.utility` or lower QoS and pause/coalesce
  while the user is actively scrolling (observe `UITrackingRunLoopMode` /
  scroll-state from the grid).
- **P7 — Measured, not assumed.** `Signposts.swift` defines named intervals
  (`launch-to-first-frame`, `snapshot-apply`, `photo-visible-latency`,
  `tap-to-transition`). M7 includes an Instruments pass on a 50k+ asset library
  on a mid-range device verifying: P1 budget, 120 Hz scroll without dropped
  frames in cached regions, and photo-capture-to-grid latency.

---

## 15. Cross-Cutting Concerns

- **Errors**: every user-initiated action surfaces failure via toast with a short
  human message; sync failures are silent except the settings status row and parked
  `failed` states. Network errors from `ImmichClient` map to a small
  `ImmichError` enum (`unauthorized`, `unreachable`, `serverTooOld`, `http(status)`, `decoding`).
- **Offline**: `RemoteLibraryService` and `ImageLoader` fail soft — grid shows
  cached thumbs; uncached remote thumbs show a placeholder tile; remote-only
  videos can't play offline ("Server unreachable" overlay on the poster); actions
  on remote facets while offline fail with a toast (no offline mutation queue in
  v1, **except** uploads which are inherently queued).
- **Info.plist / entitlements**: `NSPhotoLibraryUsageDescription`,
  `NSPhotoLibraryAddUsageDescription`, BackgroundModes (`processing`, background
  URLSession), `BGTaskSchedulerPermittedIdentifiers`, ATS per D14. (Reverse
  geocoding of EXIF coordinates needs no location permission.)
- **Privacy**: credentials only in memory during login; token in Keychain
  (`kSecAttrAccessibleAfterFirstUnlock` so background sync can auth). No analytics.
- **Logging**: `os.Logger` categories: `timeline`, `immich`, `sync`, `ui`, `perf`.

---

## 16. Testing Strategy

| Layer | Approach |
|---|---|
| `TimelineStore` | Pure unit tests with synthetic stubs + in-memory GRDB; golden tests for day/week/month boundaries, DST, year rollover, duplicate linking, mixed media-kind ordering; **incremental-apply equivalence** (applyChange sequence ≡ full rebuild). |
| `BootCache` | Round-trip fidelity, corruption and version-mismatch fallback, large-index (200k) serialize/deserialize timing assertion. |
| `ImmichClient` | `URLProtocol` stub with fixture JSON from a real Immich v3.1.0 instance; asserts paths, headers (bearer, checksum), multipart shape, playback request headers, timeout/cancellation behavior. |
| `SyncEngine` | Fake client + in-memory DB; tests dedup short-circuit, retry/backoff, scope filtering + one-way upgrade (D17), checksum invalidation after rotate, count publication. |
| `PhotoActionService` / rotators | Fake editor/client; partial-failure outcomes + rollback; unsupported-kind skip; delete-plan classification; free-up-space candidate gating (D18). M9: VideoRotator asserts stream copy (no re-encode) and correct transform on fixture movies. |
| PhotoKit/AVFoundation-touching code | Thin, manually tested; keep logic out of these classes so the untested surface is minimal. |
| UI / performance | Light XCUITest smoke (launch, grid renders, open viewer, toggle chrome). §14 P7 budgets verified with Instruments in M7; signpost names are part of the contract so the measurement is repeatable. |

---

## 17. Implementation Milestones (for the implementing agents)

Each milestone leaves the app buildable and demoable. §14 applies from M1 — the
boot cache and incremental paths are foundations, not retrofits.

1. **M1 — Skeleton + local grid**: project setup, GRDB dep, `AppEnvironment`
   (zero-I/O init) + `StartupSequencer`, PhotoKit auth, `TimelineStore` with
   **boot cache and incremental apply from day one**, grid with day grouping +
   duration badges, grouping menu, pinch columns. *(reqs 1–4; P1–P3)*
2. **M2 — Viewer**: pager, zoomable image pages, video playback pages,
   thumbnail-first transitions, chrome toggle, gradient toolbar (buttons
   stubbed), info sheet with local metadata. *(reqs 5–9; P4)*
3. **M3 — Local actions**: `AssetRotator` protocol + `ImageRotator`, optimistic
   rotate/delete with rollback, viewer wiring, unsupported-kind skip. *(req 10)*
4. **M4 — Multi-select**: selection mode, toolbar, batch actions. *(req 11)*
5. **M5 — Immich read path**: settings screen, auth session, `ImmichClient`
   (validated against the v3.1.0 spec), metadata full/delta sync with
   incremental change batches, remote thumbs in grid/viewer via merged timeline,
   remote video playback, remote metadata in info sheet, remote delete. *(reqs 12–13; P5)*
6. **M6 — Upload sync**: checksum store, bulk-upload-check, background uploads
   (photos + videos), sync scope choice + one-way upgrade (D17), backup
   indicator, settings toggle. *(req 14; P6)*
7. **M7 — Remote rotate + hardening**: replace-original rotate, partial-failure
   UX, deletion reconciliation, offline polish, **Instruments pass against the
   §14 budgets on a 50k+ library** (P7).
8. **M8 — Free Up Space (D18)**: candidate plan + byte estimate, settings row,
   batched local-only delete of server-verified assets.
9. **M9 — Video & Live Photo rotation (D10)**: `VideoRotator` (lossless
   AVMutableMovie transform remux), `LivePhotoRotator`
   (`PHLivePhotoEditingContext`), remote replacement for both, enable rotate
   controls for all kinds, confirm Live Photo paired-video handling against the
   v3.1.0 spec.

---

## 18. Resolved at Review

**2026-08-18, round 1:**
1. **Videos are in v1** → D3, §10.1, §13.2, M2/M6.
2. **Target Immich v3.1.0**; gate at ≥ v3.0 → D8. Implementers still validate
   endpoint shapes against the target server's `/api/docs`.
3. **Delete always deletes everywhere**; local-only deletion exists solely as the
   separate "Free Up Space" feature → D11, D18, M8.
4. **Sync scope chosen at sign-in** ("all" vs "new items only"), with a one-way
   upgrade to "all" later in Settings → D17, §12, §13.4.

**2026-08-18, round 2:**
5. **Video & Live Photo rotation wanted eventually** → rotation is a per-kind
   strategy behind `AssetRotator` from day one; `MediaKind` (not a bool) in the
   domain model and schema; video rotation will be lossless transform-remux;
   ships M9 → D3, D10, §8, M9.
6. **Performance is paramount** → boot cache + staged startup (D19), incremental
   timeline updates + optimistic mutations (D20), and the §14 responsiveness
   contract with measurable budgets (P1–P7), enforced from M1.

---

## 19. Implementation Log

### M1 — complete (2026-08-18)

Delivered: Xcode project (hand-written `project.pbxproj` using Xcode 16+
filesystem-synchronized groups, so new source files need no project edits), GRDB
7.11.1 via SPM, zero-I/O `AppEnvironment` + `StartupSequencer`, `LocalLibraryService`,
`TimelineIndex`/`TimelineStore` with boot cache and incremental apply, `ImageLoader`,
`AppDatabase` (schema migrated, opens lazily), and the grid with day/week/month
grouping, pinch columns, and video duration badges. 37 unit tests, all passing.

Verified on an iPhone 17 simulator against a 74-item library (65 generated photos with
EXIF dates and GPS, 3 videos, 6 stock images): 3-column default grid, correct
newest-first ordering, `Today`/`Yesterday`/week-range/month headers, pinch stepping to
5 columns, duration badges (`0:04`, `0:23`, `1:15`), boot-cache repaint on relaunch
with grouping and column count persisted, and — the D20 path — 68 assets added by
`simctl addmedia` appearing in the running app without a rebuild.

### Deviations from the design (all deliberate; the design text above is updated to match)

| Area | Design said | Built instead | Why |
|---|---|---|---|
| `LocalLibraryService` | `@MainActor final class` | plain `final class`, `@unchecked Sendable` | Every method touches the photo database; §14 P3 forbids that on the main thread. PhotoKit is thread-safe. |
| `ImageLoader` | `actor`, `AsyncStream<UIImage>` per request | thread-safe `final class`, `requestImage(…) -> ImageRequestToken` + `cancel` | Cells issue and cancel a request on every reuse during a flick; an actor hop and a per-cell `AsyncStream` allocation cost responsiveness (P4) for no safety gain. The P3 guarantee (no main-thread decode) is unchanged. |
| `GridScreen` | SwiftUI nav/toolbar wrapping the grid | SwiftUI wrapper hosting a UIKit `UINavigationController` | The grid owns its nav bar, grouping menu and (M2) the custom zoom transition; a SwiftUI-owned toolbar does not survive that. |
| `TimelineStore` | index logic inline in the actor | ordering logic extracted to a pure `TimelineIndex` value type | Makes the D20 invariant directly testable — `testIncrementalMutationsMatchFullRebuild` asserts an incremental sequence equals a full rebuild. |
| — | (not specified) | new `PHAssetResolver` | Stubs hold no `PHAsset`, and resolving one identifier per cell is a photo-DB query per tile. Batches lookups behind a bounded LRU. |

### M2 — complete (2026-08-18)

Delivered: the full-screen viewer (requirements 5–9). Horizontally-paging `UICollectionView`
(not `UIPageViewController`) with `ViewerPageCell` hosting either a `ZoomablePhotoView` or a
`VideoPlayerPageView`; `ViewerZoomAnimator` flying from the tapped tile using the already-decoded
grid thumbnail; direct-manipulation swipe-down dismissal; the gradient `ViewerToolbar`; and the
SwiftUI `InfoSheet` backed by `MetadataService`.

Verified on the simulator: tap opens the viewer, horizontal swipe pages between assets with
correct aspect-fit for both landscape and portrait, single tap toggles toolbar *and* status bar,
swipe-down returns to the grid, videos autoplay with a working scrubber and elapsed/remaining
times, rotate controls are correctly disabled on video pages (D10), and the info sheet renders
filename, capture date, dimensions with megapixels, file size, camera/lens/exposure/focal length,
a map with reverse-geocoded place name, and the availability badge.

Two real bugs found and fixed during verification:

* `ZoomablePhotoView` computed its zoom scales only on bounds changes, so an image arriving
  after the last layout pass left the image view at zero size and the page rendered black.
  `setImage` now reconfigures explicitly, and the scale limits are relaxed before resetting to
  1× because `UIScrollView` clamps `zoomScale` to the *existing* range — a stale range from the
  previous image would otherwise distort the new one.
* The video scrubber overlapped the toolbar buttons: the toolbar's controls were pinned to the
  top of its gradient area rather than its bottom safe area, and the video inset was computed in
  `cellForItemAt` when `safeAreaInsets` were still zero. Controls are now bottom-pinned and the
  inset is applied at layout time.

Rotate and delete remain wired to no-ops pending M3's `PhotoActionService`; the controls are
present and correctly enabled/disabled by media kind so the layout is final.

### Notes for later milestones

* `GridLayoutProvider` sizes tiles by giving the item `fractionalWidth(1/columns)` and
  letting the group repeat it. `repeatingSubitem:count:` was tried first and does **not**
  constrain width — a lone item in a section stretches to the full row. Do not "simplify"
  it back.
* `BootCacheTests.testLargeIndexRoundTripStaysWithinLaunchBudget` currently asserts a
  loose 1 s ceiling for a 200k-stub decode. Tighten it against a real device measurement
  during the M7 Instruments pass (P7); a 200k index is ~14 MB on disk and decode is on
  the critical path to first frame.
* Verifying UI changes from screenshots alone has already produced one phantom bug and one
  mis-aimed tap in this repo. See [AGENTS.md](AGENTS.md) — get a non-visual reading (accessibility
  tree, runtime frame log, `Tools/pixelprobe.swift`) before changing layout code.
* `TimelineStore.rebuildIndex()` has the M5 merge point marked: remote stubs join the
  array there, before `index.replaceAll`.
* `StartupSequencer.runStartupSequence()` has the M5 (`deltaSync`) and M6 (`SyncEngine.kick`)
  hook points marked in order.
