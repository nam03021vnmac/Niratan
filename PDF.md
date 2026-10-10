# PDF Support — Implementation Plan

**Status:** Initial implementation is present in `Features/PDF/`, `Models/PDF.swift`, and the native PDF window/view bridges. Native text and Japanese OCR share lookup/Unicode-range resolution; continuous viewports use a bounded visible-page queue, zoom is persisted, and adjacent soft-wrapped native lines are joined conservatively. Generated-fixture tests cover dictionary-backend integration, glyph hit geometry, click/drag policy, encrypted-document restrictions, caches, source preservation and persistence. This document remains the target plan, not a claim that every P0 acceptance row has been verified. Complex native layouts/ruby and actual click/nested-popup/Profile-switch acceptance still need the manual matrix below.

**Audience:** The coding agent implementing this feature.

**Repository baseline inspected:** `609d2d7` (`feat/pdf-support`). Recheck the working tree and nearby implementations before starting.

## 1. Goal and acceptance boundary

Add local PDF reading to the single native macOS 26+ Niratan app. Users must be able to:

1. Import/open a PDF and read its original fixed layout.
2. Click Japanese text to open the existing dictionary popup.
3. Do the same on scanned/image-only pages after automatic, on-device Japanese OCR.
4. Read a mixed PDF whose individual pages use embedded text or OCR as appropriate.
5. Navigate, zoom, close, and reopen at their last reading position without changing the source PDF.

**Japanese horizontal and vertical text are required for both text extraction and OCR lookup.** OCR recognition quality is inherently imperfect, but vertical pages cannot be excluded or routed through an API known to support only horizontal text.

### Required first release (P0)

- A local PDF library, file picker, file drop, and Finder Open With routing.
- Native PDF rendering, continuous and single-page modes, previous/next page, page-number input, fit page/width, zoom, and full screen.
- Page-local embedded-text extraction and character hit-testing.
- Automatic Japanese OCR for pages without usable text; an explicit “Recognize This Page” override for incomplete/broken text layers.
- Shared click-to-dictionary popup, matched-text highlighting, nested lookup, dictionary audio, and correct dismissal.
- Native drag selection/copy for embedded text; copy recognized block text from the OCR context menu.
- Non-destructive library storage, resume position, bounded work/caches, cancellation, localized errors, and Chinese/English UI strings.
- Focused behavioral tests plus actual PDF UI verification in the exact new build.

### Follow-up work, not prerequisites for P0

Full-document search/OCR indexing, outline and thumbnail sidebars, two-page spreads/RTL spread order, Shift-hover lookup, OCR-text drag selection, annotation editing, OCR correction UI, searchable-PDF export, page-image Anki mining, PDF statistics, cloud/Fushi sync, remote downloads, and audiobook alignment. Standard text-only actions already provided by the shared popup should keep working; do not build a PDF-specific Anki client.

## 2. Architecture decisions

### 2.1 Native PDFKit surface; shared learning pipeline

Use Apple's `PDFKit` (`PDFDocument`, `PDFPage`, `PDFView`) through a narrow `NSViewRepresentable` bridge. SwiftUI owns the library, toolbar, status, and popup composition. AppKit owns PDF pointer input, coordinate conversion, and the dedicated reader window.

PDF is a fixed-layout document format with native text selection and links. Keep it in `Features/PDF/`, rather than converting it into EPUB chapters or permanently rasterizing every page into the Manga library. This is a PDF-specific document surface, not a replacement Manga reader. Existing local/remote manga still uses `MangaReadingSession` / `MangaPageContentProvider` unchanged.

Both PDF text sources must produce the same page-text model and flow into:

```text
PDFPage embedded text ──────────────┐
                                   ├─ PDFPageText → PDFTextHit
PDF page raster → Japanese OCR ────┘                   │
                                                      ▼
                                   TextSelectionResolver.lookupCandidate
                                                      │
                                                      ▼
                                               SelectionData
                                                      │
                                                      ▼
                             PopupPresentationCoordinator → PopupView
```

There must be no PDF-specific dictionary database, deinflector, popup HTML/CSS renderer, nested-lookup implementation, or pronunciation player.

### 2.2 Product placement and ownership

- Add a **PDF** main-sidebar section backed by its own local catalog. Reuse `ShelfBookCard`, `ShelfCoverFrame`, and the existing shelf background/components where applicable; do not generalize the EPUB catalog just to store PDFs.
- Retain one `PDFLibraryViewModel` at the main root, as the current Bookshelf and Manga models are retained.
- Open PDFs in one dedicated PDF reader window using the existing coordinator/presenter pattern. Opening a different PDF saves the current position and replaces the session; reopening the current document focuses it.
- PDF catalog and reading progress are App-global, local-only. Lookup settings and popup actions use the explicitly resolved active Profile.
- Source documents are read-only. Store metadata, covers, OCR, and progress only in App-owned locations. Library removal never deletes or rewrites the source.
- Keep the one `Niratan` target/scheme. PDFKit and Vision are system frameworks; no new helper executable, target, platform bridge, or remote OCR dependency is needed.

### 2.3 Existing implementation map

Read these before coding; paths describe the inspected baseline, not new APIs promised by this plan.

| Concern | Existing reference and intended use |
| --- | --- |
| App routing | `NativeMac/AppOpenURLRoute.swift`, `NativeMac/NativeMacRootView.swift`: currently non-video local files reach EPUB import. Route PDFs before that fallback. |
| Main navigation | `NativeMac/NativeMacSection.swift`, `NativeMac/NativeMacSidebarView.swift`, `NativeMac/NativeMacDetailView.swift`, `NativeMac/HoshiNativeMacApp.swift`: add the PDF section and coordinator environment. |
| Window lifetime | `NativeMac/ReaderWindowCoordinator.swift`, `NativeMac/ReaderWindowPresenter.swift`, `NativeMac/MangaWindowCoordinator.swift`, `NativeMac/MangaWindowPresenter.swift`: study model ownership, teardown, focus, and final save. |
| Local library safety | `Features/Manga/MangaLibraryStore.swift`: read-only security-scoped bookmarks, App-owned catalog, source recovery. Reuse patterns, not the Manga data schema. |
| Candidate resolution | `Core/SelectionLookup/TextSelectionResolver.swift`: consume text plus a UTF-16 offset, rather than implementing new Japanese tokenization. |
| Popup | `Features/Popup/PopupPresentationCoordinator.swift`, `Features/Popup/PopupModels.swift`, `Features/Popup/PopupView.swift`, `Features/Manga/MangaReaderView.swift`: shared presentation and native-surface hosting. |
| OCR | `Features/Manga/OCR/MangaVisionOCREngine.swift`: already uses macOS 26 `RecognizeDocumentsRequest` for vertical Japanese. Its `RecognizeTextRequest` path explicitly does not support that case. |
| OCR policies | `Features/Manga/MangaOCREngineRouter.swift`, `Features/Manga/OCR/MangaOCRLineLayout.swift`, `Features/Manga/OCR/MangaOCRReadingOrder.swift`, `Features/Manga/MangaOCRService.swift`: reference ordering, cache identity, and cancellation. |
| Profile activation | `Core/ProfileRepository.swift`, `Core/ProfileActivationCoordinator.swift`, `Core/LookupEngine.swift`: lookup engine/configuration are shared and tied to explicit global Profile activation. |
| Shortcuts | `Core/Shortcuts/`, `Features/Settings/ApplicationShortcutRegistry.swift`, `Features/Manga/MangaShortcutActions.swift`: register scoped actions through the existing registry. |
| Isolation/build | `NativeMac/DevelopmentDataIsolation.swift`, `.codex/skills/hoshi-reader-mac-workflow/`: new stores must respect Debug data-root redirection. |

**Important reuse limits:** Manga's Vision implementation removes spaces/newlines, sometimes groups detector crops into a single string, and generally exposes line rather than precise character geometry. It is not a lossless PDF text extractor. `PopupPresentationCoordinator.present` currently has no `profileID` parameter and calls the globally configured `LookupEngine`; passing a Profile only to `PopupView` cannot fix a mismatched lookup engine.

## 3. Proposed files and interfaces

Names below are proposed. Keep responsibilities and boundaries even if nearby naming patterns suggest small changes.

| New file/boundary | Responsibility |
| --- | --- |
| `Models/PDF.swift` | Codable library record, source revision, progress, reader preferences; value-only text/geometry models may live separately if large. |
| `Features/PDF/PDFLibraryStore.swift` | Actor/serialized repository for import, bookmarks, deduplication, metadata, relink, progress, and atomic persistence. |
| `Features/PDF/PDFLibraryViewModel.swift`, `PDFLibraryView.swift` | Library loading, import/drop, cards, missing-file state, removal, and open actions. |
| `Features/PDF/PDFDocumentSession.swift` | Session ID, source lease, worker ownership, revision, page metadata, and cancellation. |
| `Features/PDF/PDFReaderViewModel.swift`, `PDFReaderView.swift` | Navigation/restore, visible pages, settings, OCR states, and shared popup composition. |
| `Features/PDF/PDFPageText.swift`, `PDFTextGeometry.swift` | Source-independent blocks, ranges, transforms, hit resolution, and match geometry. |
| `Features/PDF/PDFEmbeddedTextExtractor.swift` | PDFKit text/glyph extraction and conservative usability assessment. |
| `Features/PDF/PDFPageRasterizer.swift` | Bounded off-main rasterization with an explicit reversible page-to-pixel transform. |
| `Features/PDF/PDFOCRService.swift`, `PDFTextCache.swift` | Japanese recognition adaptation, queue/deduplication, page states, and versioned cache. |
| `Features/PDF/PDFLookupCoordinator.swift` | Candidate/selection construction, Profile snapshot, shared popup state, and root highlight lifetime. |
| `Features/PDF/PDFShortcutActions.swift` | Window-scoped page/zoom/back actions. |
| `NativeMac/NativePDFView.swift` | PDFView wrapper, pointer arbitration, coordinate conversion, transient overlay, and event callbacks. |
| `NativeMac/PDFWindowCoordinator.swift`, `PDFWindowPresenter.swift` | Single model per open request, window focus/replacement, close/termination save, and teardown. |
| `Core/OCR/VisionDocumentTextRecognizer.swift` | Small source-neutral Vision document-recognition primitive, if extracted as described below. |

### 3.1 Model contract

Define and document at least:

- `PDFLibraryItem`: stable UUID, title, optional author, read-only bookmark, last-known source identity, content revision, page count, imported/opened timestamps, progress, and reader preferences. The title comes from metadata or filename; renaming it updates catalog metadata only.
- `PDFReadingProgress`: zero-based physical page index, normalized point within the displayed crop, timestamp. Presentation uses one-based numbering and can additionally show PDF page labels; labels are never identity keys.
- `PDFSourceRevision`: streaming SHA-256 digest plus file size/modification/resource identity used to detect replacement. A URL or basename alone is not a content revision.
- `PDFPageText`: page/revision identity, crop box, intrinsic rotation, provider/signature, blocks, and extraction quality/provenance.
- `PDFTextBlock`: stable page-local ID, original text, writing direction, reading order, line spans, and geometry-bearing text spans. All stored text ranges use UTF-16 with bounds checks.
- `PDFTextSpan`: block-relative range, page-space rectangle/quad(s), and geometry quality (`exact` or `estimated`). Preserve original text and an explicit source-to-normalized mapping when normalization is needed.
- `PDFTextHit`: page/block ID, block-relative UTF-16 offset, anchor geometry, text-source provenance, session/revision generation.

Keep PDFKit/Vision objects out of Codable/Sendable models. Do not invent persistent EPUB character offsets for PDF progress.

## 4. Import, routing, persistence, and recovery

1. Add a picker accepting `UTType.pdf` and a `public.pdf` Viewer entry in `HoshiReader-Info.plist`. Use the system type; do not redeclare PDF as a private UTI. Preserve existing document registrations.
2. Picker, drop, and Finder routing call one import/open service. Check type/content and PDF readability, rather than trusting only a lowercase extension. Import multiple selections serially with per-file errors; a failed file must not roll back successful imports.
3. Resolve/acquire a read-only security-scoped bookmark. Retain access for the complete display/worker lifetime, including hashing and OCR; balance release only after owned work has stopped. Refresh stale bookmarks atomically after successful resolution.
4. Validate document opening, finite/nonzero page geometry, and page count before publishing a usable record. Corrupt/empty PDFs produce a recoverable localized error. For encrypted PDFs, show an unlock sheet; retain the password only in memory for that session and its workers. Wrong password/cancel leaves no partial successful import or leaked worker. Respect PDFKit document permissions; OCR must not silently bypass an explicit extraction restriction.
5. Deduplicate a repeated source by resource identity/bookmark resolution, with standardized URL only as fallback. The same basename in different folders is not a duplicate. Retain a stable item ID on reopen/relink so progress survives.
6. Generate a bounded first-page cover asynchronously. A failed cover must not prevent opening an otherwise readable document.
7. Persist a versioned `pdf_library.json` under the App's existing Application Support root, using injected base URLs in tests and atomic writes. Keep an unreadable/newer-schema catalog intact and report the error instead of replacing it with an empty file.
8. On missing access/source, keep the card and progress and offer Locate File/Retry/Remove from Library. An identical relink keeps caches; a different content digest invalidates only derived data for that document. Clamp out-of-range progress when page count shrinks and report that the source changed.
9. Debounce ordinary progress writes and flush the last valid position on document replacement, window close, and app termination. Serialize writes and reject older session generations so delayed saves cannot overwrite newer progress. Ignore programmatic restore callbacks until restore is complete.
10. Removing a card removes its index entry and optionally its own rebuildable caches, never the PDF. New files and caches must use normal redirected directory APIs so `--data-root` isolates them.

Keep PDFs out of current EPUB/Google Drive/Fushi serialization and import paths. No existing book sidecar migration is required for this independent catalog.

## 5. PDF display and input

- Start in vertical continuous mode, with single-page mode available. Let PDFKit render vector pages at the current display resolution; OCR bitmaps are not the display surface.
- Implement fit page, fit width, a bounded zoom control, page indicator/input, previous/next, and native full screen. Define numeric zoom relative to PDFKit's scale factor; persist fit mode separately from explicit scale so resize does not overwrite a fit preference.
- Restore after the document and view geometry are ready. The same normalized page point must remain meaningful across window size, zoom, and Retina changes.
- Let precise trackpad scrolling pan/scroll the native PDF surface. Do not reuse EPUB trackpad swipe-to-turn behavior or swallow ordinary scroll events for lookup.
- Add a `.pdf` shortcut scope/category and actions through the existing registry/manager, including settings/conflict-checker support. One key event should trigger one action; page input and IME text fields retain editing ownership. Escape dismisses a popup first, then transient UI, then exits full screen/closes according to existing window conventions.

### Pointer arbitration

Use a PDFView subclass or a local recognizer proven not to break PDFKit's responder behavior. A window-independent/permanent event monitor is not acceptable.

1. Record mouse-down position/page; allow PDFKit to perform normal selection handling.
2. A plain primary mouse-up with no drag beyond a small documented threshold (initially 4 view points) and click count 1 can initiate lookup.
3. Drag selection, double/triple click, modified selection, right click, links, and form/annotation controls retain native behavior. Recognize link/control hits before offering dictionary lookup.
4. A blank-area click must not choose the nearest character. It dismisses the active lookup.
5. Clicks inside the shared popup must not fall through to PDFView or start navigation.
6. Normal PDF links can navigate; do not execute embedded PDF JavaScript/actions beyond supported native navigation. Page navigation closes stale popup state.

Preserve native embedded-text Copy. For OCR pages, provide a native context-menu action to copy the selected recognized block; P0 does not require synthesizing a writable PDF text layer.

## 6. Embedded text and fallback policy

### 6.1 Extract lazily, per page

Do not decide document-wide support from `PDFDocument.string != nil`. A PDF may mix scans, selectable pages, covers, and unusable hidden text.

For the visible page(s), inspect `PDFPage.string`, character count, bounds, and selections. Candidate PDFKit APIs include `characterIndex(at:)`, `characterBounds(at:)`, `selection(for:)`, and `selectionsByLine()`; verify their exact SDK signatures and indexing behavior in phase 0.

- Map PDFKit character indices to the extracted string's UTF-16 ranges explicitly. Do not assume PDFKit indices, Swift `Character` indices, and UTF-16 code units are interchangeable.
- Validate finite, nonempty geometry intersecting the visible crop. Reject a nearest-character hit if the pointer does not fall within its actual glyph/line geometry plus a small scale-independent hit tolerance.
- Preserve original strings, punctuation, and range maps. Japanese lookup normalization must not silently move the clicked offset.
- Build blocks/lines in reading order. Horizontal lines read left-to-right/top-to-bottom; vertical columns read top-to-bottom and generally right-to-left. Keep unrelated columns, captions, and headers separate.
- Treat furigana as separate spans when geometry allows; a base-text lookup must not concatenate ruby into the main word. Avoid deleting small text solely because it is small.
- Handle ligatures, combining dakuten, supplementary-plane kanji, repeated text, duplicate hidden layers, whitespace, missing glyph bounds, and PDF content-stream order differing from visual order.
- Prefer usable embedded text over OCR. Good searchable PDFs with an existing invisible OCR layer should not be re-recognized merely because that layer is invisible.

### 6.2 Deterministic automatic decision

Expose an extraction assessment such as `usable`, `missing`, or `suspect(reason)` and test it independently. The first implementation should be conservative and versioned:

- `missing`: no non-whitespace extractable spans with valid geometry → schedule Japanese OCR for that visible page.
- `suspect`: text exists but is predominantly replacement/control/private-use characters without usable mapping, has overwhelmingly invalid geometry, or cannot be mapped back to actual character ranges → schedule OCR and retain valid native spans.
- `usable`: retain embedded text; no automatic OCR just because text is short, non-Japanese, or dictionary lookup returns no match.

Start with explicit, fixture-tested thresholds for “predominantly” (for example, more than 50% unusable non-whitespace characters); name the constants and include policy version in cache identity. Thresholds are heuristics, not proof that a text layer matches the image.

**Mixed content inside one page:** a selectable page number/header does not prove that scanned body text is available. P0 must include “Recognize This Page” on any readable/unrestricted page, including those assessed `usable`. This runs OCR and adds hits for image text; valid overlapping native text takes precedence. Automatic detection of every partially scanned region is follow-up work. This limitation must be visible in user guidance and the validation report.

“No dictionary result” is not evidence of missing selectable text and must not trigger repeated OCR.

## 7. Japanese OCR

### 7.1 Engine and reuse boundary

Use **on-device macOS 26 Vision `RecognizeDocumentsRequest`**, explicitly configured for Japanese (`ja-JP`) with automatic language detection disabled. It is the default P0 engine and requires no Niratan model download or server setup. Confirm runtime language/API availability and report unavailable/failed states accurately.

Do not make automatic PDF recognition inherit Manga's selected engine or Google Lens consent. PDF OCR must never automatically upload a page. The current Manga router can prefer installed manga-tuned models and has a separate network branch; those are not the PDF default.

Prefer a small extraction of the existing Vision document-request boundary into `Core/OCR/VisionDocumentTextRecognizer.swift`:

- Accept an image and explicit recognition configuration; return value-only paragraphs/lines/text ranges, geometry, and real confidence where available (otherwise unknown).
- Preserve text and available geometry at that boundary. Keep Manga-specific space removal, detector crops, bubble ordering, ruby heuristics, and `MangaOCRPageResult` conversion in the Manga adapter.
- PDF consumes the raw document result through its own page-text adapter. Preserve Vision document paragraph/layout ordering before applying narrowly justified Japanese corrections.
- Do not move the entire Manga OCR/model/cache stack into Core. If extracting the primitive would change Manga behavior, first implement a thin PDF Vision adapter and record the small duplicate request setup; do not block PDF on an unrelated OCR rewrite.

The existing whole-page Manga result is not enough to guarantee per-character hit accuracy. Verify available Vision range geometry in the installed SDK. Use character/range boxes where available. If only line boxes exist, split along the line's writing direction using grapheme-aware estimated advances, mark those spans `estimated`, and keep the original range map. Never report evenly divided line boxes as exact. Dense proportional text and ruby are mandatory manual tests for this fallback; if it cannot reliably pick the intended Japanese character, improve range geometry before accepting P0.

### 7.2 Rasterization and transforms

Render only the page needing recognition, against an opaque white background. Use its visible crop box and intrinsic rotation exactly once. Save the transform used for rendering with the result.

Initial configurable internal limits (not user preferences):

- Target approximately 240 DPI (`240 / 72` scale) before caps.
- Maximum 4,096 pixels on either dimension and 12 million pixels total.
- Validate finite dimensions and overflow before allocating; reject pathological page boxes with a readable error.
- One OCR/raster worker initially; retain at most current work plus a small adjacent-page request queue.
- Bound retained raster buffers to approximately 128 MiB; release intermediate images promptly. This is an App-owned buffer budget, not a claim about total PDFKit/Vision process memory.

Very small text may need later tiling. Do not silently render an unbounded high-resolution page to improve accuracy. Make render policy version part of cache identity.

Use separate PDF document instances for UI and background work. A PDFDocument/PDFPage owned by PDFView must not be passed to concurrent detached tasks. Serialize access to the worker document on a dedicated executor/queue, and pass immutable text/geometry/image results back. An actor alone does not authorize reentrant concurrent use of a non-Sendable PDFKit object; finish each PDFKit operation before awaiting unrelated work.

### 7.3 Scheduling and UI state

Use a page state machine:

```text
unloaded → extracting → embeddedReady
                      → queuedOCR → recognizing → ocrReady / noText
                                                → failed(retryable reason)
                                                → cancelled
```

An `embeddedReady` page can also have a user-requested supplemental OCR state. Keep extraction failure, recognition failure, a successful empty result, and cancellation distinct.

- Schedule automatically for missing/suspect visible pages after a short visibility debounce (initially 200 ms). Prioritize the clicked/current page; allow only a small bounded adjacent prefetch, not a whole-book OCR pass.
- Coalesce concurrent requests for the same page/revision/engine. Clicking while recognition is running shows localized “Recognizing Japanese text…” status; the user clicks again when ready. Do not open a delayed popup unexpectedly.
- Expose “Automatic Japanese OCR”, “Recognize This Page”, Cancel, and Retry. Turning automatic OCR off cancels queued automatic work but retains reusable results; manual recognition remains available.
- Cancellation must suppress result publication and pending cache writes. Forward cancellation to Vision if the API supports it; a non-interruptible call may finish privately but cannot update the replaced/cancelled session.
- Each result carries document ID, content revision, session generation, page index, and OCR-request generation. Validate these before mutating state, writing a cache, or selecting geometry.
- Navigation cancels obsolete queued work and lookup intentions; closing/replacing the document cancels the entire session. A completed result published before cancellation may remain in cache.
- Cache successful empty results so blank covers do not loop forever. Errors/cancellation are not successful empty results and remain explicitly retryable.

### 7.4 Cache identity and policy

Store OCR per page in App-owned cache storage under a PDF-specific namespace. Cache keys include:

```text
document content digest + physical page index + crop box + intrinsic rotation
+ language + engine/request revision + relevant OS version
+ recognition options + render policy version + text/geometry schema version
```

Use a streaming digest off-main without loading the entire PDF into `Data`. Opening the first page need not await the whole-file digest: use session-local results until identity is finalized, and do not reuse/write persistent OCR under an unverified revision. Compare source metadata before/after hashing and extraction; discard/retry if it changed. Size/mtime alone must not authorize reuse across an actual content replacement.

Write complete records atomically, with bounded decode sizes and validation of page/range/geometry values. Corrupt records invalidate only that cache entry. Persist text/provenance/transforms, not source PDF bytes or full-page PNGs by default. Bound disk OCR cache with an LRU policy (initial budget 256 MiB) that evicts rebuildable data only. Do not log recognized text, passwords, or private file paths.

OCR text is content-derived and language-fixed, so it can be App-global rather than duplicated per Profile. Do not persist dictionary results in this cache. Profile changes must never require clearing OCR.

## 8. Coordinates, hit-testing, and popup behavior

### 8.1 One canonical geometry space

Store text geometry in **unrotated PDF page coordinates**, including the real crop-box origin. Keep display rotation and rendering transforms explicit.

```text
Vision normalized coordinates
    ↔ OCR raster pixels (documented origin)
    ↔ PDF page coordinates (inverse of actual render transform)
    ↔ PDFView coordinates (PDFKit conversion APIs)
    ↔ popup host/root coordinates (AppKit view conversion + SwiftUI bridge)
```

Do not hand-scale popup anchors from page width or multiply point coordinates by Retina scale. Vision's normalized bottom-left origin, raster top-left indexing, PDF page boxes, flipped AppKit views, and SwiftUI's top-left geometry need named conversions. Rotation/crop handling must be tested with nonzero crop origins and 0/90/180/270-degree pages. Transform all quad corners rather than assuming the page is unrotated.

Resolve the page actually beneath the click (`PDFView` page lookup with nearest-page behavior disabled). Maintain a block/line spatial index on loaded pages so every mouse event does not scan all characters in a long document.

### 8.2 Lookup pipeline

1. Hit-test valid embedded spans, then supplemental OCR spans not superseded by native geometry. Whitespace/margins/gaps return no hit.
2. Resolve the block-relative UTF-16 offset. Keep horizontal and vertical spans in reading order so a lookup can cross wrapped lines within the same block without crossing into a neighboring column/paragraph.
3. Capture the active Profile ID and current lookup-configuration generation on the main actor. OCR is Japanese-only, but opening/clicking a Japanese PDF must not activate a different Profile.
4. Call `TextSelectionResolver.lookupCandidate(in:utf16Offset:scanLength:contentLanguage:)` using the resolved Profile language/settings. A non-Japanese Profile still follows the existing app configuration; do not secretly rebuild global dictionaries for PDF.
5. Build `SelectionData` with candidate text, containing sentence/block, popup-host rectangle, the correct candidate offset, and `.text(...)` mining context. If shortening the context to a sentence, rebase every offset to that sentence.
6. Call the existing `PopupPresentationCoordinator.present`, then host its `PopupView` stack as Manga/Video do. Pass the captured Profile ID explicitly into popup and mining context.
7. Use the returned match to highlight the source range for the popup lifetime. The coordinator returns a Swift character count, while mining offsets are UTF-16; convert using the actual candidate text, never by adding that count directly to a UTF-16 offset. Prefer the existing `TextSelectionResolver.highlightRange(for:matchedText:)` when the actual matched string is available, then apply the source range map. Highlight per-line/per-column rectangles, not a giant union box across whitespace.
8. Failed lookup clears the previous root highlight and gives the existing localized no-result state. Repeated clicks replace the root popup; nested dictionary clicks use shared stack semantics.

### 8.3 Profile and lifetime rules

PDF follows the one global Profile selected in Settings. Opening/focusing a PDF is Profile-neutral. Snapshot the Profile per lookup, not indefinitely at reader-open time: `LookupEngine.shared` cannot simultaneously serve a permanently frozen old Profile and the new global Profile.

When Settings explicitly changes Profile, dismiss old PDF popup/highlight state, invalidate pending lookup requests, and wait for the shared dictionary configuration to be ready before new lookup. Nested lookup and any in-flight popup action must use the originating explicit Profile ID or be cancelled when that stack is invalidated. Do not reread a different window's implicit current Profile halfway through an operation.

For P0, close popups on page navigation, scrolling, zoom, resize, layout changes, and document replacement. This gives a deterministic safe anchor policy; continuously tracking anchors can be added later. Keep highlights transient in a view/layer overlay or PDFView selection facilities; do not add/save PDF annotations to represent dictionary matches.

The shared popup keeps dictionary audio, custom CSS, and nested lookup. If exposing its existing Add to Anki action, supply sentence, title, explicit Profile ID, and an optional cached cover through ordinary `MiningContext`. Never fabricate Manga/Video/Sasayaki context. Preserve existing handling of unavailable mapped media; no page-image/audio support is claimed by P0. Verify any changed card path with a disposable deck or report it unverified.

## 9. UI and localization

Use macOS 26 native controls and existing Liquid Glass components. Do not introduce SwiftUI `Material`, old-system fallback chrome, or a second settings framework.

At minimum add/translate new user-visible strings in `Localizable.xcstrings` for:

- PDF library/title, Import PDF, empty state, Locate File, Remove from Library.
- Page number/count, fit page/width, continuous/single page, zoom accessibility labels.
- Automatic Japanese OCR, Recognize This Page, Cancel Recognition, Retry Recognition.
- Recognizing Japanese text…, Text ready, No text found, and Recognition failed.
- “Text recognition runs on this Mac. Only Japanese OCR is supported.”
- Guidance to use Recognize This Page when selectable headers coexist with scanned body text.
- Missing/unreadable/corrupt/locked PDF, password prompt/failure, unsupported extraction, and changed-source restore state.

Keep status unobtrusive and distinguish OCR-in-progress from a dictionary miss. Include VoiceOver labels for controls, keyboard access to the page field, and a way to copy OCR block text without relying only on color feedback.

## 10. Implementation sequence and exit gates

Complete phases in order. Check the current tree before editing; preserve unrelated work. Each phase should leave compiling code, but this plan does not authorize commits or releases.

### Phase 0 — Prove PDFKit/Vision assumptions

- [ ] Read the repository workflow and affected references; inspect current popup/Profile/shortcut code.
- [ ] With disposable Japanese PDFs, prove native horizontal/vertical extraction, character indexing, click coordinates, and native selection coexistence.
- [ ] Prove `RecognizeDocumentsRequest` recognizes horizontal and vertical scanned Japanese and inspect the available range geometry.
- [ ] Prove page → raster → page and page → view → popup conversions for rotation and nonzero crop boxes.
- [ ] Decide precise vs estimated OCR range geometry based on observed APIs. Record actual limitations in the implementation handoff, not as unqualified support claims.

**Exit:** A viable native-text and scanned-text click-to-range path is demonstrated. Resolve indexing/geometry blockers before building a large library UI.

### Phase 1 — Library, routing, and readable PDF window

- [ ] Implement models/store/bookmark ownership and focused persistence tests.
- [ ] Add PDF sidebar/library, picker/drop/Finder import, document registration, and localized states.
- [ ] Implement PDF window/model lifecycle, PDFView bridge, navigation, zoom, and resume/final-save.
- [ ] Register scoped keyboard actions and verify current EPUB/video routing remains intact.

**Exit:** A local PDF opens through all entry points, displays natively, resumes after relaunch, and remains byte-identical after import/read/remove.

### Phase 2 — Embedded-text dictionary lookup

- [ ] Implement page-text extraction, index mapping, usability policy, and canonical geometry.
- [ ] Add click-vs-drag arbitration and shared popup integration with explicit Profile lifetime.
- [ ] Implement transient matched-range highlights, nested lookup, no-result state, and dismissal.

**Exit:** Clicking known terms in horizontal and vertical selectable Japanese PDFs opens the correct shared dictionary entries; native selection/copy and links still work.

### Phase 3 — Japanese OCR fallback

- [ ] Implement the small Vision boundary/adaptation, raster worker, versioned page cache, and state machine.
- [ ] Add automatic visible-page fallback, manual page recognition, cancellation, retry, and recognized-block copy.
- [ ] Merge supplemental OCR with native spans, preferring native hits on overlaps.
- [ ] Validate empty-cache results, restart reuse, source/engine invalidation, and stale-task rejection.

**Exit:** Scanned horizontal/vertical and mixed PDFs support click lookup without a network request; blank/failed/cancelled pages have distinct correct behavior.

### Phase 4 — Acceptance and handoff

- [ ] Finish the focused tests and actual-PDF matrix below; fix discovered input/geometry/data-lifecycle failures.
- [ ] Run the full-feature build/identity verification and open the affected surfaces from that exact artifact.
- [ ] Review source-file hashes, bounded memory/queue behavior, localization, and affected regression checks.
- [ ] Update `docs/TODO.md`, architecture notes, and ordinary-user changelog only where the implemented behavior changes their truth. Update `PRIVACY.md` if its description becomes incomplete.
- [ ] Report implementation scope, commands/results, exact built app path, tested fixture categories, measured limitations, and all unverified scenarios.

## 11. Validation plan

### 11.1 Focused automated coverage

Add narrow behavioral checks using the current `script/test_*.swift` convention and `test-sources` headers, rather than tests that only grep for the new types:

| Proposed test | Essential assertions |
| --- | --- |
| `test_pdf_library_store.swift` | Atomic round-trip, bad/newer schema preservation, duplicate/same-name sources, missing/relinked source, stale save rejection, progress clamping, removal without source modification. |
| `test_pdf_text_geometry.swift` | Transform round-trips at all rotations and crop offsets, page gaps, zoom/scroll/backing-scale independence, vertical column ordering, glyph/whitespace hit rejection. |
| `test_pdf_text_selection.swift` | UTF-16/grapheme/PDFKit mapping, supplementary kanji and dakuten, wrapped terms, ruby separation, candidate/matched-range mapping, native-vs-OCR overlap precedence. |
| `test_pdf_text_policy.swift` | Text-only/scan/blank/bad-layer assessments; short valid text stays native; dictionary miss never schedules OCR; manual recognition works on header-plus-scan pages. |
| `test_pdf_ocr_cache.swift` | Revision/language/engine/render-policy keys, restart and empty-result reuse, corrupt-entry isolation, bounded decoding, and scoped LRU eviction. |
| `test_pdf_ocr_scheduler.swift` | In-flight deduplication, visible priority, finite queue/concurrency, cancellation, retry, and no publish/write from old document/request generations. Use delayed fake OCR results. |
| Existing open-route/shortcut/Profile checks | PDF routing preserves EPUB/video/search routes; focused-window scope and Profile changes invalidate stale lookups without switching Profiles. |

Use generated small PDFs/images for deterministic geometry/cache tests; they do not substitute for real PDF visual acceptance. Keep copyrighted/private PDFs out of tracked fixtures. Live OCR tests should check a small known Japanese phrase/range with documented tolerance, not exact full-page transcripts across OS releases.

### 11.2 Actual PDF acceptance matrix

Use safe copied/public-domain documents and an isolated data root. Record which rows actually ran.

| Document/scenario | Verify in the app |
| --- | --- |
| Horizontal Japanese text PDF | Instant native click lookup, several characters in one sentence, wrapped word, punctuation, drag/copy, links; no unnecessary OCR. |
| Vertical Japanese text PDF | Top-to-bottom/right-to-left range order, clicks on different columns, ruby/base distinction, correct matched highlight. |
| Horizontal Japanese scan | Automatic OCR, visible progress, correct word from several click positions, block copy, offline operation, cached reopen. |
| Vertical Japanese scan | Real dense/novel-style text and furigana; correct intended character and dictionary candidate, not merely a nonempty OCR result. |
| Mixed pages | Text → scan → blank → text navigation; independent source decisions and no repeated recognition of successful empty pages. |
| Mixed page / bad hidden layer | Native header + scanned body recognized by explicit action, overlap deduplication, native precedence, corrupt text mapping recovery. |
| Rotated/cropped pages | 0/90/180/270 degrees, nonzero crop origins, varied sizes; click and highlight stay on the visible word. |
| Window/input matrix | Continuous/single page, fit modes and zoom extremes, narrow/wide/full-screen, 1x/2x where available, precise scrolling, click vs drag/double click, text-field/IME focus. |
| Shared popup | Nested lookup, dictionary audio/CSS, repeated root clicks, no result/no dictionary, blank click/Escape and scroll/zoom dismissal. |
| Profile change | Two explicit Settings Profiles with different dictionaries, switch while popup/OCR exists, subsequent lookup uses new configuration, focus never changes Profile. |
| Persistence/failure | Close/reopen/relaunch, replace PDF session, missing/stale bookmark, relink, changed source/page count, corrupt PDF/cache/catalog, encrypted/wrong-password/cancel. |
| Resource/lifecycle | Long PDF, rapid page jumps, repeated OCR requests, cancel/close during recognition and hashing, no stale highlights/results/progress, bounded queue/cache behavior. |
| Source integrity | Hash disposable source before and after import, OCR, reading, relink, and library removal; bytes/path remain unchanged. |

If the shared OCR request code is changed, repeat existing Manga horizontal/vertical OCR and lookup checks. If shared Popup/selection/shortcuts change, perform the matching EPUB/Manga/Video smoke checks rather than claiming PDF tests cover those surfaces.

### 11.3 Commands and evidence

Follow the repository workflow; these are implementation-time commands, not evidence that PDF support has already been tested:

```bash
# After the proposed PDF tests exist:
bash script/run_tests.sh pdf

# Select these and other existing checks only for boundaries actually changed:
bash script/run_tests.sh app_open_url_route
bash script/run_tests.sh shortcut
bash script/run_tests.sh manga_ocr

# Use a fresh absolute disposable directory, never the user's active data root:
./script/build_and_run.sh --verify --instance pdf --data-root <absolute-disposable-data-root>

git diff --check
```

Check test output for skips: compilation/static tests are not proof of OCR accuracy, click handling, or popup geometry. The build must report `moe.shishamo.hoshi` and the running executable inside the exact produced `.app`; open/operate that absolute artifact, not an app selected only by name or bundle ID.

## 12. Definition of done

P0 is complete only when a user can import a selectable Japanese PDF and a scanned Japanese PDF, read both, **click the intended text and see the correct shared dictionary popup**, then reopen at the saved position. Horizontal and vertical writing, mixed-page behavior, source preservation, cancellation, Profile consistency, and real UI geometry must all have evidence. Document any unavailable fixture/hardware/live-Anki scenario explicitly; do not convert test success into an unverified usability claim.
