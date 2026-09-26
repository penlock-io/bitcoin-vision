//! Reading Penlock share strips from photos: finding each strip, telling
//! which one it is, and reading its cells. The BIP39 word pipeline is its
//! sibling, `bitcoin-vision`; this crate does not depend on it.
#![deny(missing_docs)]

pub mod bare;
pub mod cells;
pub mod locate;
pub mod marks;
pub mod model;
pub mod scanner;
pub mod sheet;
#[path = "scan.rs"]
mod strip_scan;
pub mod template;
pub mod title;

pub use bitcoin_vision_core::Homography;
/// The retained progress protocol shared with the word pipeline.
pub use bitcoin_vision_core::scan;
pub use bitcoin_vision_forms::{Font, Jitter, Rect};
pub use cells::{CellImage, crop_cell, crop_cells};
pub use image;
pub use imageproc;
pub use locate::{
    Anchors, Found, Identity, LocateError, Located, find_strip, find_strips, locate, locate_all,
};
pub use model::{CellReadings, CellRef, Model, ModelError};
pub use scanner::{
    Cell, Document, ModelBytes, Observation, Phase, Scan, ScanError, ScanOptions, ScanResult,
    Scanner, StripRegion, Strips,
};
pub use sheet::{Aids, Cut, Fill, Layout, Sheet, Strip, StripKind};
pub use strip_scan::ScannedShare;
pub use template::WORDS;
