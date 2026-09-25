//! The sixteen-slot mark field between a form's fiducials: the top
//! eight slots carry an id byte naming the form, and the bottom eight
//! an extended Hamming (8,4) codeword over a 4-bit number. Each row
//! keeps its own never-misroute guarantee: the id accepts at most one
//! flipped mark before it reads as another id's field, and the number
//! code corrects one mark and refuses two. An id with at least two
//! marks and two blanks keeps the all-blank and all-dark fields
//! foreign. The field is read off an
//! oriented form — the orientation mark settles which way is up before
//! any slot is sampled.

/// XORed over the number row's codeword: number 0 would otherwise
/// print a blank bottom row, and a blank row must never decode — with
/// the mask it sits at least two marks from every valid codeword, so
/// a smudge shaped like the id over an empty field refuses instead
/// of reading as number 0.
const NUMBER_MASK: u8 = 0b0000_0110;

/// What a present field says.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Field {
    /// The reader's own id, and the number under it.
    Own {
        /// 0–15, whatever the form makes of it.
        number: u8,
    },
    /// Another id's field: both raw bytes, untouched.
    Foreign {
        /// The top row's byte.
        id: u8,
        /// The bottom row's byte.
        bits: u8,
    },
    /// The reader's own id, but the number row fails its code: a
    /// damaged form, refused rather than guessed at.
    Damaged,
}

/// Data sits at Hamming positions 3, 5, 6 and 7; checks at 1, 2 and
/// 4; the extended parity at 0.
const DATA_BITS: [usize; 4] = [3, 5, 6, 7];

fn encode84(number: u8) -> u8 {
    debug_assert!(number < 16);
    let mut code = 0u8;
    for (k, bit) in DATA_BITS.iter().enumerate() {
        if number >> k & 1 == 1 {
            code |= 1 << bit;
        }
    }
    for check in [1u8, 2, 4] {
        let mut parity = 0u8;
        for bit in 1..8 {
            if bit & check != 0 && code >> bit & 1 == 1 {
                parity ^= 1;
            }
        }
        if parity == 1 {
            code |= 1 << check;
        }
    }
    if code.count_ones() % 2 == 1 {
        code |= 1;
    }
    code
}

fn decode84(byte: u8) -> Option<u8> {
    let mut code = byte;
    let mut syndrome = 0u8;
    for bit in 1..8 {
        if code >> bit & 1 == 1 {
            syndrome ^= bit;
        }
    }
    let parity = code.count_ones() % 2;
    match (syndrome, parity) {
        (0, 0) => {}
        (s, 1) => code ^= 1 << s,
        (_, 0) => return None,
        _ => unreachable!(),
    }
    let mut number = 0u8;
    for (k, bit) in DATA_BITS.iter().enumerate() {
        if code >> bit & 1 == 1 {
            number |= 1 << k;
        }
    }
    Some(number)
}

/// The printed field for `number` (0–15) under the id byte `id`. Bit
/// `i` of the result is slot `i`; within each row the leftmost slot is
/// the byte's most significant bit.
pub fn encode_with(id: u8, number: u8) -> u16 {
    u16::from(id.reverse_bits()) | u16::from((encode84(number) ^ NUMBER_MASK).reverse_bits()) << 8
}

/// Decodes a printed field for a reader whose own id is `own`,
/// correcting at most one mark per row.
pub fn decode_with(own: u8, field: u16) -> Field {
    let id = ((field & 0xFF) as u8).reverse_bits();
    let bits = ((field >> 8) as u8).reverse_bits();
    if (id ^ own).count_ones() > 1 {
        return Field::Foreign { id, bits };
    }
    match decode84(bits ^ NUMBER_MASK) {
        Some(number) => Field::Own { number },
        None => Field::Damaged,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const IDS: [u8; 2] = [b'P', b'W'];

    #[test]
    fn every_number_roundtrips_and_survives_one_wrong_mark() {
        for id in IDS {
            for n in 0..16 {
                let field = encode_with(id, n);
                assert_eq!(decode_with(id, field), Field::Own { number: n });
                for bit in 0..16 {
                    assert_eq!(
                        decode_with(id, field ^ (1 << bit)),
                        Field::Own { number: n }
                    );
                }
            }
        }
    }

    #[test]
    fn two_wrong_number_marks_are_damaged_and_two_wrong_id_marks_foreign() {
        for id in IDS {
            let field = encode_with(id, 5);
            for a in 0..16 {
                for b in a + 1..16 {
                    let read = decode_with(id, field ^ (1 << a) ^ (1 << b));
                    match (a < 8, b < 8) {
                        (false, false) => assert_eq!(read, Field::Damaged),
                        (true, true) => assert!(matches!(read, Field::Foreign { .. })),
                        _ => {}
                    }
                }
            }
        }
    }

    #[test]
    fn one_form_reads_the_other_as_foreign() {
        assert!(matches!(
            decode_with(b'W', encode_with(b'P', 0)),
            Field::Foreign { id: b'P', .. }
        ));
        assert!(matches!(
            decode_with(b'P', encode_with(b'W', 1)),
            Field::Foreign { id: b'W', .. }
        ));
    }
}
