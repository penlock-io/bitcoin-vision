//! Offline BIP39 photo recognition, without training or evaluation dependencies.
//!
//! The entry point is [`Scanner::start`]: a scan the caller runs on a thread
//! of its choosing and follows through its record ([`scan`]). The modules that
//! remain public describe finished scan data and review projections. The
//! stages themselves (segmentation, the label grid, joins, extent, the reading
//! pass) are private, and public only under the `research` feature, for the
//! research harness that studies them one at a time.

/// Declares a stage: public to a research build, which studies the stages
/// one at a time, and crate-private otherwise, where the only way to run one
/// is through [`Scanner`]. A research entry point the scan does not call
/// itself is dead code in a private build, and meant to be.
macro_rules! stage {
    ($(#[$meta:meta])* pub $($item:tt)*) => {
        #[cfg(feature = "research")]
        $(#[$meta])*
        pub $($item)*

        #[cfg(not(feature = "research"))]
        $(#[$meta])*
        #[allow(dead_code)]
        pub(crate) $($item)*
    };
}

#[cfg(feature = "research")]
pub mod boxes;
#[cfg(not(feature = "research"))]
mod boxes;
#[cfg(feature = "research")]
pub mod detect;
#[cfg(not(feature = "research"))]
mod detect;
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
#[cfg(feature = "research")]
pub mod fragments;
#[cfg(not(feature = "research"))]
mod fragments;
/// How a caller follows a scan: the record [`Scanner::start`] hands back.
pub use bitcoin_vision_core::scan;
#[cfg(feature = "research")]
pub mod hybrid;
#[cfg(not(feature = "research"))]
mod hybrid;
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
#[cfg(feature = "research")]
pub mod numbering;
#[cfg(not(feature = "research"))]
mod numbering;
#[cfg(feature = "research")]
pub mod page_frame;
#[cfg(not(feature = "research"))]
mod page_frame;
#[cfg(feature = "research")]
pub mod phrase;
#[cfg(not(feature = "research"))]
mod phrase;
pub mod progress;
mod read_budget;
#[cfg(any(feature = "research", feature = "scan-profile"))]
pub mod recogniser;
#[cfg(not(any(feature = "research", feature = "scan-profile")))]
mod recogniser;
#[cfg(feature = "research")]
pub mod region;
#[cfg(not(feature = "research"))]
mod region;
mod repair;
pub(crate) use bitcoin_vision_core::runtime;
#[cfg(feature = "scan-profile")]
pub use repair::set_read_workers;
#[cfg(feature = "research")]
pub mod sources;
#[cfg(not(feature = "research"))]
mod sources;
#[cfg(feature = "research")]
pub mod split;
#[cfg(not(feature = "research"))]
mod split;
#[cfg(any(feature = "research", feature = "scan-profile"))]
pub mod timing;
#[cfg(not(any(feature = "research", feature = "scan-profile")))]
mod timing;
#[cfg(feature = "research")]
pub mod vocabulary;
#[cfg(not(feature = "research"))]
mod vocabulary;
#[cfg(feature = "research")]
pub mod words;
#[cfg(not(feature = "research"))]
mod words;
#[cfg(any(feature = "research", feature = "print"))]
pub mod wordsheet;
#[cfg(not(any(feature = "research", feature = "print")))]
mod wordsheet;

pub mod output;
mod report;
pub use report::DecisionFile;
pub mod review;
mod scanner;
#[cfg(feature = "research")]
pub use joins::{JoinRead, JoinTrial};
#[cfg(feature = "research")]
pub use layout::PageLayout;
#[cfg(feature = "research")]
pub use phrase::{
    CROP_MARGIN, Calibration, CellSupport, DecisionTrace, ExtentParent, InitialOrder,
    InitialTraversal, LabelRead, MatchingRead, OrderSupport, OriginalRead, PageScan, Reader,
    WordBox, WordEvidence,
};
#[cfg(feature = "extent-experiment")]
pub use scanner::Extent;
pub use scanner::{
    Found, Layout, ModelBytes, PhotoUp, Scan, ScanError, ScanOptions, ScanResult, Scanner,
    WordRegion, Words,
};
#[cfg(feature = "research")]
pub use scanner::{check_dimensions, decode_image};
#[cfg(feature = "research")]
pub use split::Frame;
#[cfg(feature = "research")]
pub use vocabulary::Word;
#[cfg(not(feature = "research"))]
pub(crate) use vocabulary::Word;

/// A build without `research` cannot reach a stage, whether through a stage
/// module, a public module's function, or a method on a type the result
/// re-exports. Each of these fails to compile, and the scan they run inside
/// does not:
///
/// ```compile_fail
/// let _ = bitcoin_vision_words::phrase::read_words_observed;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::wordsheet::read_observed;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::sources::Segmentation::new;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::fragments::plan;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::hybrid::select;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::numbering::fit;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::PageLayout::new;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::PageLayout::selected;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::PageLayout::reach_groups;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::hybrid::select_bounded;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::Reader::load;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::detect::Detector::probability_map_with_limit;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::progress::Stage::geometry;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::detect::Detector::from_bytes;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::boxes::BoxScan::from_page;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::progress::Observer::on_event;
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::Scanner::from_models;
/// ```
/// ```compile_fail
/// fn leak(result: &bitcoin_vision_words::ScanResult) { let _ = &result.page; }
/// ```
/// ```compile_fail
/// let _ = bitcoin_vision_words::image::RgbImage::new(1, 1);
/// ```
/// ```
/// let _ = bitcoin_vision_words::Scanner::start;
/// ```
#[cfg(not(feature = "research"))]
#[doc(hidden)]
pub mod stages_are_private {}
