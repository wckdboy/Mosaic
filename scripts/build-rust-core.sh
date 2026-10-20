#!/bin/bash
# Builds the Rust engine for the Xcode target that invoked this phase.
#
# Xcode runs this before compiling Swift. Cargo is incremental, so the second and
# subsequent builds are effectively free. The static library is placed in a
# platform-specific directory that LIBRARY_SEARCH_PATHS points at.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo was not found. Install Rust from https://rustup.rs, then add the iOS targets:" >&2
    echo "  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios" >&2
    exit 1
fi

PLATFORM="${PLATFORM_NAME:-iphonesimulator}"
ARCHS_VALUE="${ARCHS:-$(uname -m)}"
OUTPUT_DIR="$ROOT/Frameworks/$PLATFORM"
mkdir -p "$OUTPUT_DIR"

targets=()
for arch in $ARCHS_VALUE; do
    case "$PLATFORM" in
        iphoneos)
            targets+=("aarch64-apple-ios")
            break
            ;;
        iphonesimulator)
            if [ "$arch" = "x86_64" ]; then
                targets+=("x86_64-apple-ios")
            else
                targets+=("aarch64-apple-ios-sim")
            fi
            ;;
        *)
            echo "warning: unsupported platform $PLATFORM; skipping Rust core" >&2
            exit 0
            ;;
    esac
done

if [ "${#targets[@]}" -eq 0 ]; then
    targets=("aarch64-apple-ios-sim")
fi

artifacts=()
index=0
for target in "${targets[@]}"; do
    if ! rustup target list --installed 2>/dev/null | grep -qx "$target"; then
        echo "error: Rust target $target is not installed. Run: rustup target add $target" >&2
        exit 1
    fi
    echo "Building MosaicCore for $target"
    cargo build \
        --release \
        --quiet \
        --manifest-path "$ROOT/rust/mosaic-core/Cargo.toml" \
        --target "$target"
    artifact="$ROOT/rust/target/$target/release/libmosaic_core.a"
    if [ ! -f "$artifact" ]; then
        echo "error: expected $artifact after cargo build" >&2
        exit 1
    fi
    artifacts+=("$artifact")
    index=$((index + 1))
done

if [ "${#artifacts[@]}" -gt 1 ]; then
    lipo -create "${artifacts[@]}" -output "$OUTPUT_DIR/libmosaic_core.a"
else
    cp "${artifacts[0]}" "$OUTPUT_DIR/libmosaic_core.a"
fi

echo "MosaicCore ready at $OUTPUT_DIR/libmosaic_core.a"
