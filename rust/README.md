# Mosaic core

The on-device engine behind Mosaic's similarity index, smart selection, collages,
and photobooks. It is a normal Rust workspace with no network, database, or cloud
dependency.

## Crates

- `mosaic-core` — the library and C ABI. Modules:
  - `index`: incremental 50k-scale visual index, parallel similarity search,
    LSH duplicate discovery, leader clustering, diversity-aware curation.
  - `layout`: deterministic, aspect-aware collage geometry for eight styles.
  - `book`: event detection, page rhythm, spreads, cover, and per-page layouts.
  - `ffi`: panic-safe JSON entry points consumed by Swift.
- `mosaic-cli` — benchmark and layout debug command.

## Swift contract

Swift calls the stable header at `mosaic-core/include/mosaic_core.h`. Every call
other than `mosaic_core_version` takes and returns UTF-8 JSON:

```json
{ "ok": true, "result": { } }
{ "ok": false, "error": "unknown item: abc" }
```

Returned strings are owned by Rust and freed with `mosaic_string_free`. The Swift
wrappers live in `Mosaic/Services/MosaicCore.swift`. Xcode runs
`scripts/build-rust-core.sh` before compiling Swift.

## Build and test

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo test --manifest-path rust/Cargo.toml --workspace
cargo run --release --manifest-path rust/Cargo.toml -p mosaic-cli -- scale 50000
```

The scale benchmark is intentionally synthetic: it measures projection, index
upsert, top-200 search, 80-item curation, clustering, duplicate grouping, and stats.
It does not measure Vision or PhotoKit, which are the real-device indexing limits.

## Design notes

- Feature prints and word vectors arrive as base64 Int8 payloads. They are projected
  once with a deterministic sparse random projection into 192 or 96 bytes. Identical
  inputs always produce identical signatures.
- Similarity is a dot product over Int8 signatures. Parallel search uses Rayon.
- Duplicate and similarity grouping use four 16-bit sign bands. Candidate buckets
  remain small at 50k items; there is no all-pairs comparison.
- Every layout is normalized to a unit square. Swift maps it to preview or export
  pixels, so the two cannot disagree.
- Layouts and selections are deterministic for a given seed. Ties break by media
  identifier so redraws never reshuffle a project.
- No unwind crosses the C ABI. The FFI wrapper catches panics and returns an error
  envelope.
