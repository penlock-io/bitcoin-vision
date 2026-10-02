//! Reading Penlock share strips from photos: finding each strip, telling
//! which one it is, and reading its cells. The BIP39 word pipeline is its
//! sibling, `bitcoin-vision`; this crate does not depend on it.
#![deny(missing_docs)]

#[cfg(feature = "research")]
pub mod bare;
#[cfg(not(feature = "research"))]
mod bare;
#[cfg(feature = "research")]
pub mod cells;
#[cfg(not(feature = "research"))]
mod cells;
#[cfg(feature = "research")]
pub mod locate;
#[cfg(not(feature = "research"))]
mod locate;
#[cfg(feature = "research")]
pub mod marks;
#[cfg(not(feature = "research"))]
mod marks;
#[cfg(feature = "research")]
pub mod model;
#[cfg(not(feature = "research"))]
mod model;
mod scanner;
#[cfg(any(feature = "research", feature = "print"))]
pub mod sheet;
#[cfg(not(any(feature = "research", feature = "print")))]
mod sheet;
#[path = "scan.rs"]
mod strip_scan;
#[cfg(feature = "research")]
pub mod template;
#[cfg(not(feature = "research"))]
mod template;
#[cfg(feature = "research")]
pub mod title;
#[cfg(not(feature = "research"))]
mod title;

/// The retained progress protocol shared with the word pipeline.
pub use bitcoin_vision_core::scan;
pub use locate::Identity;
pub use scanner::{
    Cell, Document, ModelBytes, Observation, Phase, Reading, Scan, ScanError, ScanOptions,
    ScanResult, Scanner, StripRegion, Strips,
};
pub use strip_scan::ScannedShare;

/// The default build exposes the retained scan contract, not the locator,
/// worksheet or classifier stages. Research and printing opt in explicitly.
///
/// ```compile_fail
/// let _ = penlock_scan::locate::find_strip;
/// ```
/// ```compile_fail
/// let _ = penlock_scan::cells::crop_cells;
/// ```
/// ```compile_fail
/// let _ = penlock_scan::model::Onnx::from_bytes;
/// ```
/// ```compile_fail
/// let _ = penlock_scan::sheet::front_png;
/// ```
/// ```compile_fail
/// let _ = penlock_scan::image::RgbImage::new(1, 1);
/// ```
#[cfg(not(any(feature = "research", feature = "print")))]
#[doc(hidden)]
pub mod internal_stages_are_private {}
