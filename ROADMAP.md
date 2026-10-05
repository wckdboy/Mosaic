# Mosaic roadmap and ideas

An evolving record of product ideas and release work. These are **proposals, not implemented features or delivery promises**. The [README](README.md#what-works) describes what works today. Priorities below are a suggested order; quality and measured performance should decide what ships.

## Design principles

- Keep Library and Collections as the main destinations. Add capabilities through contextual actions and Settings before adding navigation.
- Give media the space. Use progressive disclosure, clear icons with accessible labels, and short, useful copy.
- Preserve the browsing position when opening media, exploring similarities, changing filters, or returning from a task.
- Make expensive work incremental, cancellable, and bounded. Measure memory, scrolling, battery use, and thermal behavior on devices.
- Keep analysis local by default and optional. Any future remote AI needs explicit opt-in and a clear description of what leaves the device.
- Discover only media the user has authorized. Physical renames and moves remain an explicit choice with exact previews, collision protection, and recovery/Undo.

## First: release confidence

These checks take priority over expanding the feature list.

| ID | Work | Evidence needed |
| --- | --- | --- |
| Q1 | Device performance and stability | Representative older/newer iPhones and iPads; large libraries; launch and scroll measurements; memory pressure; extended playback and browsing; energy and thermal traces. Establish repeatable baselines before setting budgets. |
| Q2 | Real cloud and Files providers | Authorized test accounts for Nextcloud, Proton Drive, Google Drive, and S3; revoked access, offline/cloud-only files, expired sessions, interrupted transfers, and partial move/Undo failures. |
| Q3 | Playback compatibility | A reusable media corpus covering containers, codecs, HDR, RAW, animations, subtitles, damaged files, track changes, seeking, Bluetooth, AirPlay, and Picture in Picture. Publish observed support and limitations. |
| Q4 | Accessibility and interaction | Physical-device VoiceOver, larger text, Reduce Motion, increased contrast, light/dark appearance, rotation, iPad layouts, and repeated gallery/canvas/viewer transitions. |
| Q5 | Repeatable release checks | CI build/tests with retained results; archive migration/recovery checks; dependency/license review when adding packages; a focused security review of provider access, credentials, parsers, and original-file operations. |

## Next candidates

### F1 · Saved lenses

Save a useful search and its filters as a live view: for example, favorite videos from a source, or images matching recognized text. Reopening a lens shows the current matching library without copying media.

- **Placement:** Save from the existing search/filter surface; reopen from Collections or a compact Library shortcut.
- **First version:** Named lenses with query, media type, source, favorites, sort, and layout. Editing or deleting a lens changes only the saved view.
- **Done when:** Lenses survive relaunch, update as the library changes, handle disconnected sources clearly, and restore their browsing position. Test large-library filtering and empty results.
- **Later:** Optional color or text-sentiment criteria using existing cached analysis, with clear handling of unanalyzed items.

### F2 · Organization review inbox

A quiet, opt-in place to review suggested naming and grouping batches. Surface a useful proposal when it is ready, with a small preview and an explanation of why those items belong together.

- **Placement:** A contextual Review action in Library; no additional main tab or interrupting prompts.
- **First version:** Suggestions built from existing naming/grouping capabilities. Accept, edit, or dismiss a proposal; remember dismissals so the same suggestion does not keep returning.
- **Done when:** Every accepted batch has an exact preview, explicit scope, per-item results, and persisted Undo. Suggestions do not change originals by themselves; physical operations require the existing separate choice and confirmation.
- **Later:** Duplicate cleanup suggestions after F3 is reliable. Never automatically delete files based on similarity.

## Further possibilities

| ID | Idea | Scope and requirements |
| --- | --- | --- |
| F3 | Duplicate review | Distinguish byte-identical files from visually similar media. Compare side by side with size, resolution, and source; let the user choose what to keep. Hash originals incrementally only with authorized access and an explicit download policy. Any deletion needs its own recovery and confirmation design. |
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
