//! App timing scopes; only the explicit profile build records them.

#[cfg(feature = "scan-profile")]
pub(crate) use bitcoin_vision_words::timing::{span, take};

#[cfg(not(feature = "scan-profile"))]
/// No-op timing guard outside the opt-in profile build.
pub(crate) struct Span;

#[cfg(not(feature = "scan-profile"))]
/// No-op timing scope outside the opt-in profile build.
pub(crate) fn span(_name: &'static str) -> Span {
    Span
}
