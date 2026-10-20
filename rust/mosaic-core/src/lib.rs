//! Mosaic's on-device media intelligence and composition engine.
//!
//! The crate has three responsibilities:
//!
//! 1. A compact, incrementally updated similarity index that keeps 50,000+
//!    photo descriptors searchable in milliseconds.
//! 2. Deterministic layout generation for collages and photobooks.
//! 3. Diversity-aware curation that turns a large library into a small, varied
//!    selection suitable for a spread or a book.
//!
//! Everything here runs locally. The C ABI lives in [`ffi`] and speaks JSON so the
//! Swift layer can evolve without hand-maintained bridging structs.

pub mod book;
pub mod ffi;
pub mod geom;
pub mod index;
pub mod layout;
pub mod rng;

pub use book::{plan_book, BookItem, BookPlan, BookRequest, BookPage};
pub use index::{
    ClusterMode, IndexItem, MosaicIndex, QueryMode, QueryRequest, QueryResult, SelectRequest,
    Selection, Stats,
};
pub use layout::{layout_collage, CollageCell, CollageLayout, CollageRequest};
