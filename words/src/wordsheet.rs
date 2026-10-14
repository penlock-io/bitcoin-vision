//! The recovery phrase card: a Penlock band that holds twelve BIP39 words
//! instead of six symbols a row. It has the share strip's size, corner
//! squares, mark field, rows and look, all from [`bitcoin_vision_forms::band`],
//! so a phrase and its shares are cut, stored and photographed alike, and a
//! phone finds either by the same marks. The mark field's id byte says which
//! it is. [`WordSheet`] is the one contract: where the aids, the identity marks
//! and the twelve writable interiors are. The renderer draws from it and the
//! reader cuts from it. A field's border and number sit outside its
//! interior, so an interior holds handwriting and nothing else.
//!
//! Coordinates are millimetres in the band's reading frame. Five cards print
//! to an A4 page, each back panel behind its card for a long-edge flip.
//! Nothing secret is ever printed, and the back is for what is not secret:
//! when, which wallet, whose.

use bitcoin_vision_forms::band::{Band, BandPage, rect};
use bitcoin_vision_forms::frame::{
    Frame, Geometry, RECTIFIED_PX_PER_MM, locate_frames, paper_white, read_field,
};
use bitcoin_vision_forms::marks::{Field, decode_with, encode_with};
#[cfg(feature = "print")]
use bitcoin_vision_forms::render::flatten;
use bitcoin_vision_forms::render::{
    Font, GUIDE, INK, Jitter, Rect, RenderError, rasterize, svg_document, text,
};
use image::{GrayImage, RgbImage};
use rand::{Rng, SeedableRng};

use crate::Word;
use crate::detect::{Quad, clockwise};
use crate::numbering::Numbering;
use crate::phrase::{PageScan, Reader, WordBox, read_crop};
use crate::recogniser::Recogniser;

/// The card's version, printed in its identity marks. Version 1 was a full
/// A4 page; no reader takes it any longer.
pub const VERSION: u8 = 2;

/// The id byte the card prints in its mark field's top row: another id than
/// the strips', so a strip reader sees a phrase card as foreign and a
/// phrase-card reader sees a strip as foreign, each refusing the other by the
/// same rule that refuses any other project.
pub const WORD_SHEET_ID: u8 = b'W';

/// The repository the back's QR code and printed URL point to.
pub const REPOSITORY_URL: &str = "https://github.com/penlock-io/bitcoin-vision";

/// The card's geometry: a band's, with each row one writable field.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct WordSheet;

impl WordSheet {
    /// Fields down the card.
    pub const FIELDS: usize = Band::ROWS;
    /// A field's interior sits this far inside its printed border, so the
    /// border's ink is never read as handwriting.
    pub const MARGIN: f64 = 0.6;
    /// Five cards to an A4 page, the most its 297 mm takes at 51 mm a card.
    /// Penlock's worksheet spaces four; these keep 4 mm between cut lines.
    pub const PAGE: BandPage = BandPage {
        slots: 5,
        top: 13.0,
        pitch: 55.0,
    };

    /// Where the card's fiducials, orientation mark and mark field are, for
    /// finding it in a photo: a band's.
    pub fn geometry(&self) -> Geometry {
        Band.geometry()
    }

    /// The whole card.
    pub fn bounds(&self) -> Rect {
        Band.bounds()
    }

    /// The four fiducials: top-left, top-right, bottom-left, bottom-right.
    pub fn fiducials(&self) -> [Rect; 4] {
        Band.fiducials()
    }

    /// The orientation mark beside the top-left fiducial.
    pub fn mark(&self) -> Rect {
        Band.mark()
    }

    /// The sixteen mark-field slots; slot `i` carries bit `i` of the printed
    /// field.
    pub fn mark_slots(&self) -> [Rect; 16] {
        Band.mark_slots()
    }

    /// The printed identity: the card's id byte and its version.
    pub fn field(&self) -> u16 {
        encode_with(WORD_SHEET_ID, VERSION)
    }

    /// The printed border of field `i`: the band's row.
    pub fn frame(&self, i: usize) -> Rect {
        Band.row(i)
    }

    /// The writable interiors, in phrase order.
    pub fn fields(&self) -> [Rect; WordSheet::FIELDS] {
        std::array::from_fn(|i| self.frame(i).grow(-WordSheet::MARGIN))
    }
}

/// Words to write into the fields, for fixtures: `None` leaves a
/// field blank.
pub struct WordFill {
    /// One entry per field.
    pub words: Vec<Option<Word>>,
    /// The handwriting font.
    pub font: Font,
    /// Placement variance and its seed.
    pub jitter: Option<(Jitter, u64)>,
}

/// The card's SVG elements in its reading frame, blank or with `fill`'s
/// words, without the `<svg>` wrapper.
pub fn card_group(fill: Option<&WordFill>) -> String {
    let t = WordSheet;
    let mut s = String::new();
    Band.draw_border(&mut s);
    Band.draw_aids(&mut s, t.field());
    Band.draw_title(&mut s, "BIP39 Phrase");
    Band.draw_hint(&mut s, "Keep this secret");
    for i in 0..WordSheet::FIELDS {
        Band.draw_label(&mut s, i);
        rect(
            &mut s,
            t.frame(i),
            &format!("fill=\"#ffffff\" stroke=\"{GUIDE}\" stroke-width=\"0.3\""),
        );
    }
    if let Some(fill) = fill {
        let mut rng = fill
            .jitter
            .map(|(jitter, seed)| (jitter, rand::rngs::StdRng::seed_from_u64(seed)));
        for (i, word) in fill.words.iter().enumerate().take(WordSheet::FIELDS) {
            let Some(word) = word else { continue };
            let interior = t.fields()[i];
            // a hand writes to the field it is given: the word starts a
            // little in from the left and its letters stand most of the
            // interior's height
            let base = interior.h * 0.62;
            let (cx, cy) = (interior.x + 2.0, interior.y + interior.h / 2.0);
            let (dx, dy, size, angle) = match &mut rng {
                Some((j, rng)) => (
                    rng.random_range(-j.offset_mm..=j.offset_mm),
                    rng.random_range(-j.offset_mm..=j.offset_mm),
                    base * (1.0 + rng.random_range(-j.size..=j.size)),
                    rng.random_range(-j.rotation_deg..=j.rotation_deg),
                ),
                None => (0.0, 0.0, base, 0.0),
            };
            let glyphs = text(
                cx + dx,
                cy + dy,
                size,
                "start",
                fill.font.family(),
                INK,
                word.as_str(),
            );
            if angle == 0.0 {
                s.push_str(&glyphs);
            } else {
                s.push_str(&format!(
                    "<g transform=\"rotate({angle:.2} {:.2} {:.2})\">{glyphs}</g>\n",
                    cx + dx,
                    cy + dy
                ));
            }
        }
    }
    s
}

/// The A4 front as a self-contained SVG: blank cards in every place on the
/// page. Only a cut card is ever filled.
pub fn front_svg() -> String {
    let (w, h) = BandPage::PAGE;
    let card = card_group(None);
    let mut body = format!("<rect width=\"{w}\" height=\"{h}\" fill=\"#ffffff\"/>\n");
    for slot in 0..WordSheet::PAGE.slots {
        body.push_str(&WordSheet::PAGE.place(slot, &card));
    }
    svg_document(w, h, &body)
}

/// The A4 back as a self-contained SVG: behind each card after a long-edge
/// flip, the band's panel (date, wallet, owner) with a QR code to the
/// repository and its URL.
#[cfg(feature = "print")]
pub fn back_svg() -> String {
    let (w, h) = BandPage::PAGE;
    let modules = qr_modules(REPOSITORY_URL);
    let mut body = format!("<rect width=\"{w}\" height=\"{h}\" fill=\"#ffffff\"/>\n");
    for slot in 0..WordSheet::PAGE.slots {
        WordSheet::PAGE.draw_back_panel(
            &mut body,
            slot,
            "Scanner",
            REPOSITORY_URL.trim_start_matches("https://"),
            &modules,
        );
    }
    svg_document(w, h, &body)
}

/// `text` as QR modules, row-major, dark `true`.
#[cfg(feature = "print")]
pub fn qr_modules(text: &str) -> Vec<Vec<bool>> {
    let code = qrcode::QrCode::new(text.as_bytes()).expect("a URL fits a QR code");
    let width = code.width();
    let colors = code.to_colors();
    colors
        .chunks(width)
        .map(|row| row.iter().map(|c| *c == qrcode::Color::Dark).collect())
        .collect()
}

/// The card front then back as a two-page A4 PDF, for printing at actual
/// size on both sides with a long-edge flip.
#[cfg(feature = "print")]
pub fn sheet_pdf() -> Result<Vec<u8>, RenderError> {
    let (w, h) = BandPage::PAGE;
    let front = flatten(&front_svg(), w, h)?;
    let back = flatten(&back_svg(), w, h)?;
    bitcoin_vision_forms::pdf::document(&[&front, &back], BandPage::PAGE)
}

/// The card cut out along its border, as a self-contained SVG in its
/// reading frame, blank or filled.
pub fn card_svg(fill: Option<&WordFill>) -> String {
    svg_document(Band::WIDTH, Band::LENGTH, &card_group(fill))
}

/// The cut card rendered at `dpi`, blank or filled.
pub fn card_png(fill: Option<&WordFill>, dpi: f64) -> Result<RgbImage, RenderError> {
    rasterize(&card_svg(fill), dpi)
}

/// Ink in a field's interior is this much darker than the paper.
const INK_SHARE_OF_WHITE: f64 = 0.6;
/// Fewer ink pixels than this at [`RECTIFIED_PX_PER_MM`] is a blank
/// field: under a square millimetre, a speck or a fibre.
const MIN_INK_PIXELS: usize = 50;
/// The tight box round the ink grows by this much on every side.
const INK_PAD_MM: f64 = 1.0;

/// The tight box round the handwriting in `interior`, in frame
/// millimetres, or `None` when the interior is blank.
fn ink_bounds(rectified: &GrayImage, interior: &Rect, px_per_mm: f64) -> Option<Rect> {
    let dark = (paper_white(rectified) * INK_SHARE_OF_WHITE) as u8;
    let x0 = (interior.x * px_per_mm).round().max(0.0) as u32;
    let y0 = (interior.y * px_per_mm).round().max(0.0) as u32;
    let x1 = (((interior.x + interior.w) * px_per_mm).round() as u32).min(rectified.width());
    let y1 = (((interior.y + interior.h) * px_per_mm).round() as u32).min(rectified.height());
    let (mut count, mut lo_x, mut lo_y, mut hi_x, mut hi_y) =
        (0usize, u32::MAX, u32::MAX, 0u32, 0u32);
    for y in y0..y1 {
        for x in x0..x1 {
            if rectified.get_pixel(x, y)[0] < dark {
                count += 1;
                lo_x = lo_x.min(x);
                lo_y = lo_y.min(y);
                hi_x = hi_x.max(x);
                hi_y = hi_y.max(y);
            }
        }
    }
    if count < MIN_INK_PIXELS {
        return None;
    }
    let tight = Rect {
        x: f64::from(lo_x) / px_per_mm - INK_PAD_MM,
        y: f64::from(lo_y) / px_per_mm - INK_PAD_MM,
        w: f64::from(hi_x - lo_x + 1) / px_per_mm + 2.0 * INK_PAD_MM,
        h: f64::from(hi_y - lo_y + 1) / px_per_mm + 2.0 * INK_PAD_MM,
    };
    // never past the interior: the frame's ink is outside it
    let x = tight.x.max(interior.x);
    let y = tight.y.max(interior.y);
    Some(Rect {
        x,
        y,
        w: (tight.x + tight.w).min(interior.x + interior.w) - x,
        h: (tight.y + tight.h).min(interior.y + interior.h) - y,
    })
}

stage! {
    /// Whether `gray` shows one recovery phrase sheet of this version: its
    /// fiducials and orientation mark found as one frame, and its mark
    /// field decoding to the sheet's id and version. A strip, an ordinary
    /// page or any other marks give `None`. The sheet comes back with its
    /// face-on view for the fields to be cut from.
    pub fn identify(gray: &GrayImage) -> Option<(Frame, GrayImage)> {
        let geometry = WordSheet.geometry();
        let located = match locate_frames(gray, geometry) {
            Ok(mut all) if all.len() == 1 => all.remove(0),
            _ => return None,
        };
        let rectified = located.rectify(gray, RECTIFIED_PX_PER_MM);
        let field = read_field(&rectified, &geometry);
        if field.count_ones() <= 1 {
            return None;
        }
        match decode_with(WORD_SHEET_ID, field) {
            Field::Own { number } if number == VERSION => Some((located, rectified)),
            _ => None,
        }
    }
}

stage! {
    /// Reads a photographed word sheet field by field, the crops read by
    /// `crop_reader`: `Ok(None)` when the photo's marks do not establish a
    /// word sheet of this version, so the detector path is the one to
    /// take; `Ok(Some)` with exactly twelve records in field order once
    /// every field is read, a blank one at its place; `Err` when an
    /// identified sheet cannot be read, which is a failure to report, never
    /// a page to hand to the detector.
    pub fn read_with(
        photo: &RgbImage,
        crop_reader: &dyn Fn(&RgbImage, &Quad) -> Result<WordBox, String>,
    ) -> Result<Option<PageScan>, String> {
        read_with_observed(photo, crop_reader, None).map(|value| value.map(|(scan, _)| scan))
    }
}

stage! {
    /// [`read_with`] with field progress in canonical photo coordinates. The caller
    /// owns terminal delivery, including errors here and subsequent result packing.
    pub fn read_with_observed(
        photo: &RgbImage,
        crop_reader: &dyn Fn(&RgbImage, &Quad) -> Result<WordBox, String>,
        observer: Option<&dyn crate::progress::Observer>,
    ) -> Result<Option<(PageScan, Vec<crate::progress::FinalRegion>)>, String> {
        use crate::progress::{RegionState, Stage};
        let gray = image::DynamicImage::ImageRgb8(photo.clone()).into_luma8();
        let Some((located, rectified)) = identify(&gray) else {
            return Ok(None);
        };
        crate::progress::emit(observer, || {
            let card = WordSheet.bounds();
            crate::progress::Event::Form {
                outline: [
                    (card.x, card.y),
                    (card.x + card.w, card.y),
                    (card.x + card.w, card.y + card.h),
                    (card.x, card.y + card.h),
                ]
                .map(|(x, y)| {
                    let (px, py) = located.to_photo(x, y);
                    (px as f32, py as f32)
                }),
            }
        });
        let mut progress = Stage::geometry(observer, WordSheet::FIELDS);
        let quads: Vec<_> = WordSheet
            .fields()
            .iter()
            .enumerate()
            .map(|(i, interior)| {
                let tight = ink_bounds(&rectified, interior, RECTIFIED_PX_PER_MM).unwrap_or(*interior);
                let corners = [
                    (tight.x, tight.y),
                    (tight.x + tight.w, tight.y),
                    (tight.x + tight.w, tight.y + tight.h),
                    (tight.x, tight.y + tight.h),
                ]
                .map(|(x, y)| {
                    let (px, py) = located.to_photo(x, y);
                    (px as f32, py as f32)
                });
                let quad = Quad(clockwise(corners));
                progress.region(i, &quad, RegionState::Found);
                quad
            })
            .collect();
        progress.reading();
        let mut words = Vec::with_capacity(WordSheet::FIELDS);
        for (i, quad) in quads.into_iter().enumerate() {
            progress.region(i, &quad, RegionState::Reading);
            let mut word = crop_reader(photo, &quad).map_err(|e| format!("field {}: {e}", i + 1))?;
            word.column_rank = i;
            word.row_rank = i;
            crate::phrase::DecisionTrace::push(&mut word.evidence.decisions, || {
                serde_json::json!({"rule":"worksheet_layout","status":"evaluated",
                    "field":i,"reason":"registered field; no freeform label, region or replacement passes"})
            });
            progress.settled(i, &word);
            progress.read_done(i + 1);
            words.push(word);
        }
        progress.checking();
        let mut scan = PageScan {
            page_direction: None,
            width: photo.width(),
            height: photo.height(),
            words,
            numbering: Numbering::None,
            join_trials: Vec::new(),
            sources: Vec::new(), // Registered fields, not raw detector observations.
        };
        let regions = progress.into_regions();
        crate::phrase::history::terminal(&mut scan, &regions, "scan_return");
        Ok(Some((scan, regions)))
    }
}

stage! {
    /// [`read_with`] through the stage's own crop reading: the word model,
    /// the recogniser, the keep rule and the pick, and no number looked for,
    /// since a field holds nothing but its word.
    pub fn read(
        photo: &RgbImage,
        reader: &Reader,
        recogniser: Option<&Recogniser>,
        margin: f32,
    ) -> Result<Option<PageScan>, String> {
        read_with(photo, &|photo, quad| {
            read_crop(photo, quad, reader, recogniser, margin)
        })
    }
}

stage! {
    /// [`read`] with optional native field observations and a final identity map.
    pub fn read_observed(
        photo: &RgbImage,
        reader: &Reader,
        recogniser: Option<&Recogniser>,
        margin: f32,
        observer: Option<&dyn crate::progress::Observer>,
    ) -> Result<Option<(PageScan, Vec<crate::progress::FinalRegion>)>, String> {
        read_with_observed(
            photo,
            &|photo, quad| read_crop(photo, quad, reader, recogniser, margin),
            observer,
        )
    }
}
