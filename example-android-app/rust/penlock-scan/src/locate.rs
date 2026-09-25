//! Finding strips in a photo and reading which strip each one is.
//!
//! A strip is a form with corner fiducials, found by
//! [`bitcoin_vision_forms::frame`], or an upstream strip without them,
//! found by its shaded checksum boxes ([`crate::bare`]). Which strip it
//! is comes from its mark field, or on a strip from before the field
//! from the printed identity code, read by blob presence at its six
//! positions and decoded through the distance-4 codebook: one wrong
//! mark is corrected, two make it [`Identity::Unknown`], never another
//! strip.

use std::fmt;

pub use bitcoin_vision_forms::frame::RECTIFIED_PX_PER_MM;
use bitcoin_vision_forms::frame::{Frame, FrameError, MARK_INK, ink_fraction, paper_white};
use image::GrayImage;
use penlock::ShareIndex;

use crate::cells::{CellImage, crop_cells};
use crate::sheet::{Layout, Strip, StripKind};

/// Prints a line of the locator's reasoning to stderr when
/// `PENLOCK_TRACE` is set, for finding out why a photo did not read.
pub(crate) fn trace(args: fmt::Arguments<'_>) {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    if *ON.get_or_init(|| std::env::var_os("PENLOCK_TRACE").is_some()) {
        eprintln!("{args}");
    }
}

/// What a strip was found by.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Anchors {
    /// The four corner squares and the orientation mark.
    Fiducials,
    /// The shaded checksum boxes of a strip without scan aids, oriented
    /// by the letter boxes' borders.
    ChecksumBoxes,
}

impl fmt::Display for Anchors {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Anchors::Fiducials => f.write_str("corner squares"),
            Anchors::ChecksumBoxes => f.write_str("checksum boxes (no corner squares)"),
        }
    }
}

/// Where a strip is in a photo, and how it was found.
#[derive(Clone, Debug)]
pub struct Located {
    /// The strip's frame: where its fiducials are, printed or not.
    pub frame: Frame,
    /// What it was found by.
    pub anchors: Anchors,
    /// Which boxes it prints.
    pub layout: Layout,
}

/// Why no strip could be found.
#[derive(Clone, PartialEq, Debug)]
pub enum LocateError {
    /// Fewer than four solid square blobs.
    TooFewFiducials {
        /// Candidates found.
        found: usize,
    },
    /// No quadruple of solid squares has the sizes its homography implies
    /// and reprojects the orientation mark onto a mark-sized blob.
    FiducialsMismatched,
    /// Four squares of consistent size, but no mark-sized blob where the
    /// orientation mark should be in any orientation.
    NoOrientationMark,
    /// More than one strip where exactly one was expected.
    Several(usize),
    /// A mark field whose id byte is not Penlock's: another project's
    /// strip, its raw bytes preserved.
    UnsupportedProject {
        /// The top row's byte.
        id: u8,
        /// The bottom row's byte.
        bits: u8,
    },
    /// A mark field present but invalid beyond one mark: a damaged
    /// versioned strip, refused rather than read as anything older.
    MarkFieldDamaged,
    /// No corner squares, and too few rows of checksum boxes to stand in
    /// for them.
    NoChecksumBoxes {
        /// Rows of boxes found.
        rows: usize,
    },
    /// Checksum boxes found, but which way up the strip is could not be
    /// told from the letter boxes' borders.
    NoOrientation,
}

impl fmt::Display for LocateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooFewFiducials { found } => {
                write!(f, "found {found} of the 4 corner squares")
            }
            Self::FiducialsMismatched => {
                write!(f, "no four squares fit together as one card's corners")
            }
            Self::NoOrientationMark => {
                write!(
                    f,
                    "corners found but not the orientation mark beside the top-left one"
                )
            }
            Self::Several(n) => write!(
                f,
                "{n} strips in one photo; photograph one cut strip at a time, or pass the sheet with --sheet"
            ),
            Self::UnsupportedProject { id, bits } => write!(
                f,
                "the mark field carries project id {id:#04x} (bits {bits:#04x}): not a Penlock strip"
            ),
            Self::MarkFieldDamaged => write!(
                f,
                "the mark field is damaged beyond one mark; refusing to guess what the strip is"
            ),
            Self::NoChecksumBoxes { rows } => write!(
                f,
                "no corner squares, and only {rows} of the 12 rows of shaded boxes to go by"
            ),
            Self::NoOrientation => write!(
                f,
                "shaded boxes found but not which way up the strip is; photograph it flat with the whole strip in frame"
            ),
        }
    }
}

impl std::error::Error for LocateError {}

impl From<FrameError> for LocateError {
    fn from(e: FrameError) -> LocateError {
        match e {
            FrameError::TooFewFiducials { found } => LocateError::TooFewFiducials { found },
            FrameError::FiducialsMismatched => LocateError::FiducialsMismatched,
            FrameError::NoOrientationMark => LocateError::NoOrientationMark,
        }
    }
}

/// Finds every strip in `photo`, in reading order: by their corner
/// fiducials, or failing that as one upstream strip by its checksum boxes.
pub fn locate_all(photo: &GrayImage) -> Result<Vec<Located>, LocateError> {
    match bitcoin_vision_forms::locate_frames(photo, Strip.geometry()) {
        Ok(frames) => Ok(frames
            .into_iter()
            .map(|frame| Located {
                frame,
                anchors: Anchors::Fiducials,
                layout: Layout::Aided,
            })
            .collect()),
        // Nothing with corner squares was accepted, whatever the miss:
        // the strip may be upstream's, which has none. If its boxes were
        // found, the bare path's miss is the one worth reporting.
        Err(aided) => match crate::bare::locate_bare(photo) {
            Ok(bare) => Ok(vec![bare]),
            Err(bare @ LocateError::NoOrientation) => Err(bare),
            Err(_) => Err(aided.into()),
        },
    }
}

/// Finds the one strip in `photo`; several is [`LocateError::Several`].
pub fn locate(photo: &GrayImage) -> Result<Located, LocateError> {
    let mut all = locate_all(photo)?;
    match all.len() {
        1 => Ok(all.remove(0)),
        n => Err(LocateError::Several(n)),
    }
}

/// Which strip a located strip is, from its printed identity code.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Identity {
    /// The seed-phrase strip.
    Seed,
    /// A share strip.
    Share(ShareIndex),
    /// The code could not be read: two or more marks wrong, or a
    /// defaced strip.
    Unknown,
}

impl Identity {
    /// The share index, if this is a share strip.
    pub fn share(self) -> Option<ShareIndex> {
        match self {
            Identity::Share(i) => Some(i),
            _ => None,
        }
    }
}

impl fmt::Display for Identity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Identity::Seed => f.write_str("seed phrase"),
            Identity::Share(i) => write!(f, "share {i}"),
            Identity::Unknown => f.write_str("unknown strip"),
        }
    }
}

impl From<StripKind> for Identity {
    fn from(kind: StripKind) -> Identity {
        match kind {
            StripKind::Seed => Identity::Seed,
            StripKind::Share(i) => Identity::Share(i),
        }
    }
}

/// A located strip cut into the cells a model reads.
#[derive(Clone, Debug)]
pub struct Found {
    /// Where the strip is.
    pub located: Located,
    /// The strip face-on at [`RECTIFIED_PX_PER_MM`].
    pub rectified: GrayImage,
    /// Which strip it is, from the printed code.
    pub identity: Identity,
    /// What the mark field says the strip's format is: always legacy
    /// or a recognised version. Any other field never becomes a
    /// `Found` — it is a [`LocateError`] instead.
    pub format: crate::marks::Format,
    /// Every row's cells, in word order.
    pub cells: Vec<[CellImage; 6]>,
}

/// Reads the sixteen-slot mark field and dispatches the format: a
/// Penlock field carries the sheet number, a confidently absent field
/// falls back to the legacy six-mark code, and anything else is
/// refused outright — a foreign project's field (raw bytes preserved)
/// or a damaged one must fail loudly, never misread as legacy.
pub fn read_format(rectified: &GrayImage) -> Result<(crate::marks::Format, Identity), LocateError> {
    use crate::marks::{Field, Format};
    let field = bitcoin_vision_forms::read_field(rectified, &Strip.geometry());
    // One dark slot is not a field: a legacy strip must survive a
    // single spurious mark, and every real field prints at least four
    // — the id's two and the number row's masked minimum.
    if field.count_ones() <= 1 {
        return Ok((Format::Legacy, read_identity(rectified)));
    }
    match crate::marks::decode(field) {
        Field::Own { number } => {
            let identity = if number == 0 {
                Identity::Seed
            } else {
                ShareIndex::new(number).map_or(Identity::Unknown, Identity::Share)
            };
            Ok((Format::Penlock { number }, identity))
        }
        Field::Foreign { id, bits } => Err(LocateError::UnsupportedProject { id, bits }),
        Field::Damaged => Err(LocateError::MarkFieldDamaged),
    }
}

/// Reads the identity code off a rectified strip. Ink is judged against
/// the strip's own paper white, since a solid square has no white of its
/// own to compare with.
pub fn read_identity(rectified: &GrayImage) -> Identity {
    let white = paper_white(rectified);
    let read: [bool; 6] = Strip
        .code_positions()
        .map(|r| ink_fraction(rectified, r.grow(-0.4), RECTIFIED_PX_PER_MM, white) > MARK_INK);
    StripKind::decode(read).map_or(Identity::Unknown, Identity::from)
}

/// Cuts a located strip: rectifies it, reads its identity, crops its cells.
pub fn cut(photo: &GrayImage, located: Located) -> Result<Found, LocateError> {
    let rectified = located.frame.rectify(photo, RECTIFIED_PX_PER_MM);
    let (format, identity) = match located.anchors {
        Anchors::Fiducials => read_format(&rectified)?,
        Anchors::ChecksumBoxes => (
            crate::marks::Format::Legacy,
            crate::title::read_title(&rectified, RECTIFIED_PX_PER_MM),
        ),
    };
    let cells = crop_cells(&rectified, RECTIFIED_PX_PER_MM, located.layout);
    Ok(Found {
        located,
        rectified,
        identity,
        format,
        cells,
    })
}

/// Finds the one strip in `photo` and cuts it.
pub fn find_strip(photo: &GrayImage) -> Result<Found, LocateError> {
    cut(photo, locate(photo)?)
}

/// Finds every strip in `photo` and cuts each, in reading order.
pub fn find_strips(photo: &GrayImage) -> Result<Vec<Found>, LocateError> {
    locate_all(photo)?
        .into_iter()
        .map(|l| cut(photo, l))
        .collect()
}
