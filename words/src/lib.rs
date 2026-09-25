//! Offline BIP39 photo recognition, without training or evaluation dependencies.
//!
//! The entry point is [`Scanner::start`]: a scan the caller runs on a thread
//! of its choosing and follows through its record ([`scan`]). The modules that
//! remain public define what a scan returns and the models it runs on. The
//! stages themselves (segmentation, the label grid, joins, extent, the reading
//! pass) are private, and public only under the `research` feature, for the
//! research harness that studies them one at a time.

pub mod boxes;
pub mod detect;
#[cfg(feature = "research")]
pub mod dot_grid;
#[cfg(not(feature = "research"))]
mod dot_grid;
#[cfg(all(
    feature = "word-extent",
    any(feature = "research", feature = "extent-experiment")
))]
pub mod extent;
#[cfg(all(
    feature = "word-extent",
    not(any(feature = "research", feature = "extent-experiment"))
))]
mod extent;
pub mod fragments;
/// Re-exported from `bitcoin-vision-core`, which both pipelines depend on.
pub use bitcoin_vision_core::homography;
/// How a caller follows a scan: the record [`Scanner::start`] hands back.
pub use bitcoin_vision_core::scan;
pub mod hybrid;
#[cfg(feature = "research")]
pub mod inference_limit;
#[cfg(not(feature = "research"))]
mod inference_limit;
#[cfg(feature = "research")]
pub mod joins;
#[cfg(not(feature = "research"))]
mod joins;
#[cfg(feature = "research")]
pub mod layout;
#[cfg(not(feature = "research"))]
mod layout;
pub mod numbering;
pub mod page_frame;
#[cfg(feature = "research")]
pub mod phrase;
#[cfg(not(feature = "research"))]
mod phrase;
pub mod progress;
mod read_budget;
pub mod recogniser;
#[cfg(feature = "research")]
pub mod region;
#[cfg(not(feature = "research"))]
mod region;
mod repair;
#[doc(hidden)]
pub use bitcoin_vision_core::runtime;
#[cfg(feature = "scan-profile")]
pub use repair::set_read_workers;
pub mod sources;
#[cfg(feature = "research")]
pub mod split;
#[cfg(not(feature = "research"))]
mod split;
pub mod timing;
pub mod vocabulary;
pub mod words;
pub mod wordsheet;

pub mod output;
mod scanner;
pub use image;
pub use joins::{JoinRead, JoinTrial};
pub use layout::PageLayout;
pub use phrase::{
    CROP_MARGIN, Calibration, CellSupport, DecisionTrace, ExtentParent, InitialOrder,
    InitialTraversal, LabelRead, MatchingRead, OrderSupport, OriginalRead, PageScan, Reader,
    WordBox, WordEvidence,
};
#[cfg(feature = "extent-experiment")]
pub use scanner::Extent;
pub use scanner::{
    Found, Layout, ModelBytes, Scan, ScanError, ScanOptions, ScanResult, Scanner, WordRegion,
    Words, check_dimensions, decode_image,
};
pub use split::Frame;
pub use vocabulary::Word;
