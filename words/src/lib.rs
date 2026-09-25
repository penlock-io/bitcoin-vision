//! Offline BIP39 photo recognition, without training or evaluation dependencies.
//!
//! The high-level entry point is [`Scanner`]. Low-level geometry modules expose
//! the same implementation for integrations and diagnostics; they are not a
//! separate recognition pipeline.

pub mod boxes;
pub mod detect;
#[doc(hidden)]
pub mod dot_grid;
#[cfg(feature = "word-extent")]
pub mod extent;
pub mod fragments;
/// Re-exported from `bitcoin-vision-core`, which both pipelines depend on.
pub use bitcoin_vision_core::homography;
/// How a caller follows a scan: the record [`Scanner::start`] hands back.
pub use bitcoin_vision_core::scan;
pub mod hybrid;
pub mod inference_limit;
pub mod joins;
pub mod layout;
pub mod numbering;
pub mod page_frame;
pub mod phrase;
pub mod progress;
mod read_budget;
pub mod recogniser;
pub mod region;
mod repair;
#[doc(hidden)]
pub use bitcoin_vision_core::runtime;
#[cfg(feature = "scan-profile")]
pub use repair::set_read_workers;
pub mod sources;
pub mod split;
pub mod timing;
pub mod vocabulary;
pub mod words;
pub mod wordsheet;

pub mod output;
mod scanner;
pub use image;
#[cfg(feature = "extent-experiment")]
pub use scanner::Extent;
pub use scanner::{
    Found, Layout, ModelBytes, Scan, ScanError, ScanOptions, ScanResult, Scanner, WordRegion,
    Words, check_dimensions, decode_image,
};
pub use vocabulary::Word;
