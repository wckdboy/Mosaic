# Contributing to Mosaic

Mosaic is developed locally with Xcode. A hosted repository is not required to build, test, or contribute.

## Code style

- Write clearly commented code. Unlike some sibling Omnie projects, Mosaic favors comments that explain what a non-trivial piece of code does and why, not just the non-obvious parts — optimize for a reader with no prior context.
- Prefer small Swift types with one clear responsibility.
- Use four-space indentation and descriptive names.
- Use Swift concurrency (`async`/`await`) rather than Combine for new asynchronous work.
- Avoid force unwraps and hidden global state.
- Follow `BRANDING.md` for anything user-facing: monochrome UI, the single purple-to-orange accent, Liquid Glass used only on controls/navigation, and native platform behavior (Dynamic Type, system fonts, system motion).

## Tests

Run Product > Test in Xcode before sharing a change. File and media handling should be tested against temporary/sample data, covering both success and failure paths.

## Changes that need extra care

File access, media indexing, and anything touching on-device ML models can affect user data or performance. Keep these changes focused and document the verification performed in the pull request description.

## Formatting

The repository includes `.swift-format` with four-space indentation. Run:

```sh
xcrun swift-format format --configuration .swift-format --in-place --recursive Mosaic MosaicTests MosaicUITests
```

Explain ownership, cancellation, persistence, and performance tradeoffs in comments. Avoid comments that simply repeat a statement. Keep explanatory product copy in Settings rather than expanding the browsing interface.

## Boundaries worth preserving

- Never delete or move originals as a side effect of organizing references. Physical changes belong only to the explicit Original files workflow, with exact-path preview, confirmation, collision refusal, journal-before-move ordering, and recoverable Undo.
- Keep file-provider security scopes alive for the entire read/playback lifetime.
- Perform media decoding, folder enumeration, and analysis off the main actor.
- Bound caches and analysis batches. Do not replace canvas viewport lookup with an all-items scan per frame.
- Keep credentials in Keychain and signed URLs ephemeral. Tests must not need real cloud secrets.
- Label interactive media cells explicitly; their images are decorative.
- Respect Reduce Motion and preserve pan gestures while a photo is zoomed.

The shared Mosaic scheme includes MosaicTests and MosaicUITests. UI tests generate a separate temporary library using the Debug-only `--ui-testing` launch argument; they must never request access to a person's Photos library or cloud account. Keep accessibility audits and both swipe directions covered when changing browsing controls. Performance tests record clock/memory metrics with generous regression ceilings; compare equivalent hardware and build configurations.

Xcode MCP tools can build, run tests, and verify simulator interactions. A simulator pass does not substitute for hardware HDR/AirPlay/PiP, VoiceOver traversal, sustained memory/energy profiling, or real file-provider testing.
