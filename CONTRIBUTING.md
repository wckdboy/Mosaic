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
