//! The sixteen-slot mark field between a strip's fiducials, split by
//! meaning: the top eight slots carry a project id byte — Penlock's is
//! the ASCII capital P — and the bottom eight an extended Hamming
//! (8,4) codeword over the 4-bit sheet number. Each row keeps its own
//! never-misroute guarantee: the id accepts at most one flipped mark
//! before it reads as another project's field, and the number code
//! corrects one mark and refuses two. The all-blank and all-dark
//! fields can never read as the id byte. The field is read off an
//! oriented strip — the orientation mark settles which way is up
//! before any slot is sampled. docs/marks.md records the convention;
//! the codec is [`bitcoin_vision_forms::marks`].

pub use bitcoin_vision_forms::marks::Field;
use bitcoin_vision_forms::marks::{decode_with, encode_with};

/// The byte Penlock prints in the top row.
pub const PROJECT_ID: u8 = b'P';

/// What the mark field says a strip is: always legacy or a Penlock
/// field — anything else never becomes a `Found`, it is a locate
/// error instead.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Format {
    /// A strip carrying Penlock's field.
    Penlock {
        /// The sheet number: 0 the seed strip, 1–15 the shares.
        number: u8,
    },
    /// No field between the fiducials: a strip from before the field,
    /// identified by whatever marking its print carries.
    Legacy,
}

/// The printed field for sheet `number` (0 the seed strip, 1–15 the
/// shares). Bit `i` of the result is slot `i`; within each row the
/// leftmost slot is the byte's most significant bit.
pub fn encode(number: u8) -> u16 {
    encode_with(PROJECT_ID, number)
}

/// Decodes a printed field, correcting at most one mark per row;
/// [`Field::Own`] is a Penlock strip and its sheet number.
pub fn decode(field: u16) -> Field {
    decode_with(PROJECT_ID, field)
}
