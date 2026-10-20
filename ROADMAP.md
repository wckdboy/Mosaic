# Mosaic roadmap and ideas

An evolving record of product ideas and release work. These are **proposals, not implemented features or delivery promises**. The [README](README.md#what-works) describes what works today. Priorities below are a suggested order; quality and measured performance should decide what ships.

## Design principles

- Keep Library, Create, and Collections as the main destinations. Add capabilities through contextual actions and Settings before adding navigation.
- Give media the space. Use progressive disclosure, clear icons with accessible labels, and short, useful copy.
- Preserve the browsing position when opening media, exploring similarities, changing filters, or returning from a task.
- Make expensive work incremental, cancellable, and bounded. Measure memory, scrolling, battery use, and thermal behavior on devices.
- Keep analysis local by default and optional. Any future remote AI needs explicit opt-in and a clear description of what leaves the device.
- Discover only media the user has authorized. Physical renames and moves remain an explicit choice with exact previews, collision protection, and recovery/Undo.

## Shipped foundation

These are implemented and documented in the README; the roadmap keeps the *next* work separate.

| ID | Work | State |
| --- | --- | --- |
| S1 | Rust engine for similarity, clustering, duplicates, curation, and layout | Collage, photobook, smart picks, and the canvas at library scale use `rust/mosaic-core` through a JSON C ABI. 50k-item benchmark is part of the repo. |
| S2 | Create destination | Collage studio, photobook studio, smart picks, saved recipes, high-resolution image export, and multi-page PDF export. |
| S3 | Large-library indexing | Three workers on battery, six while charging, thermal pauses, measured throughput, 10-minute cache checkpoints, and incremental Rust index updates. |
| S4 | Project recipes | Creations persist stable identifiers, style, seed, finish, chapter titles, cover choice, and story focus; geometry is rebuilt from the current library. |
| S5 | Collect while browsing | The viewer's Add to project menu targets any book or collage; a collect bar adds the current photo while swiping and shows the live count. |
| S6 | Project shelf | Searchable, filterable shelf for every book and collage with rename, duplicate, kind filters, and deletion. |
| S7 | Location-aware chapters | Photos capture locations split chapters by distance; optional reverse geocoding names chapters and is cached locally. |
| S8 | Story focus | Smart curate uses on-device word meanings to favor photos that fit an idea such as ocean, family, or celebration. |
| S9 | Saved views | Save a query, media type, favorites/source filter, and sort from the gallery or canvas; the live view appears in Collections and reopens against the current library. |

### Next on the create surface

| ID | Work | Scope |
| --- | --- | --- |
| C1 | Real print ordering | A print-provider integration with size, paper, shipping, and price previews. Keep the local PDF/share path working without an account. |
| C2 | Per-cell crop and focus | Let someone drag a photo inside its cell and persist a focal point. The Rust cells already carry normalized focus coordinates. |
| C3 | Text and page furniture | Optional page titles, dates, captions, and end pages with editable typography. Keep text out of the collage canvas by default. |
| C4 | Collage templates from a photo | Suggest a layout based on dominant colors, orientation, and faces present. Do not identify people. |
| C5 | Book proofing | Spread-level review with crop warnings, low-resolution badges, duplicate warnings, and a printable contact sheet before export. |
| C6 | Chapter editing | Rename, split, merge, or reorder detected events; pin an event to a page range. |
| C7 | Export presets | Bleed, safe margins, CMYK-aware PDF, and per-provider page sizes. Measure file size and color conversion on device. |

## First: release confidence

These checks take priority over expanding the feature list.

| ID | Work | Evidence needed |
| --- | --- | --- |
| Q1 | Device performance and stability | Representative older/newer iPhones and iPads; large libraries; launch and scroll measurements; memory pressure; extended playback and browsing; energy and thermal traces. Establish repeatable baselines before setting budgets. |
| Q2 | Real cloud and Files providers | Authorized test accounts for Nextcloud, Proton Drive, Google Drive, and S3; revoked access, offline/cloud-only files, expired sessions, interrupted transfers, and partial move/Undo failures. |
| Q3 | Playback compatibility | A reusable media corpus covering containers, codecs, HDR, RAW, animations, subtitles, damaged files, track changes, seeking, Bluetooth, AirPlay, and Picture in Picture. Publish observed support and limitations. |
| Q4 | Accessibility and interaction | Physical-device VoiceOver, larger text, Reduce Motion, increased contrast, light/dark appearance, rotation, iPad layouts, and repeated gallery/canvas/viewer transitions. |
| Q5 | Repeatable release checks | CI build/tests with retained results; archive migration/recovery checks; dependency/license review when adding packages; a focused security review of provider access, credentials, parsers, and original-file operations. |
| Q6 | Print and export fidelity | Verify collage and PDF exports at 100% on a calibrated display and a physical print. Check rounded corners, focal crops, page bleed, text, color profiles, memory, and cancellation on large books. |
| Q7 | 50k-library device pass | Measure first enumeration, thumbnail analysis throughput, thermal state, battery, memory, and foreground responsiveness on older and newer iPhones and iPads with 50,000+ photos. Establish a budget for the Rust index and cache checkpoint. |

## Next candidates

### F2 · Organization review inbox

A quiet, opt-in place to review suggested naming and grouping batches. Surface a useful proposal when it is ready, with a small preview and an explanation of why those items belong together.

- **Placement:** A contextual Review action in Library; no additional main tab or interrupting prompts.
- **First version:** Suggestions built from existing naming/grouping capabilities. Accept, edit, or dismiss a proposal; remember dismissals so the same suggestion does not keep returning.
- **Done when:** Every accepted batch has an exact preview, explicit scope, per-item results, and persisted Undo. Suggestions do not change originals by themselves; physical operations require the existing separate choice and confirmation.
- **Later:** Duplicate cleanup suggestions after F3 is reliable. Never automatically delete files based on similarity.

## Further possibilities

| ID | Idea | Scope and requirements |
| --- | --- | --- |
| F3 | Duplicate review | The Rust engine already finds visual duplicate groups and smart picks suppress bursts. A review surface still needs side-by-side comparison with size, resolution, and source, an explicit keep/remove choice, recovery, and confirmation. Hash originals incrementally only with authorized access and an explicit download policy. Any deletion needs its own recovery and confirmation design. |
| F4 | Reusable organization recipes | Save naming patterns, collection rules, and optional folder destinations. Start with user-triggered dry runs using the existing move journal and Undo. Consider scheduled suggestions only after provider interruption/recovery is proven. |
| F5 | Tags and ratings | Fast contextual tagging and batch edits; expose criteria through lenses. Keep Mosaic metadata separate from embedded-file metadata unless the user explicitly chooses to write originals. |
| F6 | Offline selections | Pin chosen media for offline viewing with a visible storage budget, Wi-Fi preference, progress, cancellation, and eviction controls. Handle revoked access and provider limitations; avoid silently downloading whole libraries. |
| F7 | Unified cloud browsing | Explore including S3 references in collections, search, and the canvas. Requires stable identities, incremental listing, bounded thumbnail caching, renewed access URLs, and useful offline states. |
| F8 | Direct cloud connections | Investigate native Nextcloud/WebDAV and Google Drive integrations alongside Files providers. Evaluate Proton Drive only against supported integration options. Research authentication, API availability, scope, licensing, and maintenance before committing to an implementation. Keep credentials in Keychain and connection details in Settings. |
| F9 | Broader decoding | Evaluate an alternate decoder such as VLCKit or FFmpeg for unsupported media. Prototype seeking, track selection, subtitles, cancellation, and recovery; review distribution/license obligations and measure binary size, energy, HDR, AirPlay, and PiP behavior before choosing a dependency. |
| F10 | Player refinements | Playback queue, chapters, timestamp bookmarks, bounded scrub previews, and per-file track/subtitle preferences. Explore ASS/SSA, external audio, and equalization separately. Keep frequent controls close and advanced options in the existing playback panel. |
| F11 | More animation and image formats | Investigate animated WebP and improve the published compatibility matrix. Require bounded frame caching, prompt cancellation, and graceful handling of malformed or unusually large assets. |
| F12 | Optional semantic search | Explore small on-device embeddings for concepts and related scenes beyond the current composition hash. Cache results in resource-limited batches and explain the basis of matches. No default remote analysis, face identification, or claims to infer a person's emotions. |
| F13 | Spatial memory and discovery trails | Save a canvas viewpoint and provide a compact trail when following several Find similar hops. Restore the original item and viewport reliably; avoid adding persistent chrome or retaining full-resolution media for history. |
| F14 | Portable organization data | Export/import collections, lenses, tags, and display names in a versioned format without credentials. Design stable media matching and conflict previews first. Optional encrypted metadata sync is a separate investigation, with conflict resolution and no implicit upload of originals. |
| F15 | Share sheet and Shortcuts | Explore collecting media through a share extension and user-triggered actions for opening lenses or preparing organization previews. Respect sandbox grants; automation must not bypass original-file confirmations. |

## Turning an idea into work

Reference its ID in an issue or pull request, and record:

1. The user problem and the smallest useful interaction, including where it lives in the existing UI.
2. Permission, privacy, offline, cancellation, and recovery behavior.
3. Performance budgets and meaningful tests, including accessibility where the UI changes.
4. Acceptance criteria and any investigation needed before implementation.

When a feature ships, update the README with its actual behavior and limitations, then mark or move its entry here. Keep exploratory ideas distinct from release commitments.
