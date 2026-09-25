//! What both bitcoin-vision pipelines stand on, and nothing either one owns.
//!
//! A module is here because the BIP39 word pipeline and the Penlock strip
//! pipeline both call it today, not because it sounds general: admitting an
//! image under one set of limits, the homography both use to rectify, and the
//! ONNX execution contract both models are run through.

pub mod admit;
pub mod homography;
#[doc(hidden)]
pub mod runtime;

pub use admit::{ImageError, check_dimensions, decode_image};
pub use homography::Homography;
