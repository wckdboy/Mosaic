//
//  MosaicCore-Bridging-Header.h
//  Mosaic
//
//  Exposes the Rust engine's stable C ABI to Swift. The header itself is shared with
//  the Rust build and must stay free of Objective-C or Swift types.
//

#import "../rust/mosaic-core/include/mosaic_core.h"
