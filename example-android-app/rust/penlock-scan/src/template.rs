//! What the strip draws that no other form does: its twelve rows, its
//! shaded checksum boxes, and where a cell's symbol is set. The drawing
//! primitives are [`bitcoin_vision_forms::render`]; the worksheet itself
//! is [`crate::sheet`].

use bitcoin_vision_forms::render::BASELINE_SHIFT;
use penlock::Share;
use penlock::word::symbols_to_string;

/// Words on a strip: a 12-word share, one row each.
pub const WORDS: usize = 12;

pub(crate) const CHECKSUM_FILL: &str = "#f2f2f2";
/// Upstream shades its checksum boxes mid-grey.
pub(crate) const UPSTREAM_CHECKSUM_FILL: &str = "#a8a8a8";
pub(crate) const CELL_FONT_SIZE: f64 = 6.5;

/// Where a symbol's text element sits for a cell centred at `(cx, cy)`,
/// as it appears in [`crate::sheet::strip_group`]'s output.
pub fn cell_text_anchor(cx: f64, cy: f64) -> (f64, f64) {
    (cx, cy + CELL_FONT_SIZE * BASELINE_SHIFT)
}

/// Symbols of a share as the characters written on the card, for display.
pub fn share_rows(share: &Share) -> Vec<String> {
    share
        .words()
        .iter()
        .map(|w| symbols_to_string(*w))
        .collect()
}
