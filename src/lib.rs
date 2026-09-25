//! Read handwritten bitcoin data from a photograph, offline.
//!
//! Two pipelines, each its own crate and each a feature here, both on by
//! default: [`words`] reads a handwritten BIP39 recovery phrase, and
//! [`penlock`] reads Penlock share strips. A consumer that wants only one
//! can depend on its crate directly, `bitcoin-vision-words` or
//! `penlock-scan`, or turn the other feature off.

#![deny(missing_docs)]

#[cfg(feature = "words")]
#[doc(inline)]
pub use bitcoin_vision_words as words;
#[cfg(feature = "penlock")]
#[doc(inline)]
pub use penlock_scan as penlock;
