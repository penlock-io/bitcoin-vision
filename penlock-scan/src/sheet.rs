//! The upstream A4 worksheet, front and back, plus what a camera needs.
//!
//! Geometry is measured from the vendored `worksheet-12.pdf` at 100%: four
//! strips stacked down the page — `Seed Phrase`, `Share 1`, `Share 2`,
//! `Share 3` — each printed sideways, with twelve columns of six boxes (the
//! two shaded checksum boxes at the bottom of each column), dashed cut
//! borders, and on the back a date/wallet/owner panel and the static
//! recovery QR. Added inside every strip's cut border: four corner
//! fiducials, an orientation mark and a printed identity code read by
//! geometry, and dropout-grey box borders. Nothing secret is printed and
//! every sheet is identical.
//!
//! A strip is described in its **reading frame** — held with the title at
//! the top it is a bookmark [`Strip::WIDTH`] across and [`Strip::LENGTH`]
//! long, each word a row of six boxes read left to right as the worksheet
//! line `CC LLLL` — and placed on the page by a quarter turn, exactly as
//! upstream prints it.

use std::fmt;

use image::RgbImage;
use penlock::word::{WORD_LEN, Word, symbols_to_string};
use penlock::{Share, ShareIndex, Symbol};
use rand::{Rng, RngCore, SeedableRng};

use bitcoin_vision_forms::Geometry;
pub use bitcoin_vision_forms::band::BackPanel;
use bitcoin_vision_forms::band::{Band, BandPage, rect};
use bitcoin_vision_forms::render::{
    Font, GUIDE, INK, Jitter, Rect, RenderError, TEXT, flatten, rasterize, svg_document, text,
};

use crate::template::{CELL_FONT_SIZE, CHECKSUM_FILL, UPSTREAM_CHECKSUM_FILL, WORDS};

/// A4 portrait, millimetres.
pub const PAGE: (f64, f64) = (210.0, 297.0);

/// Which strip of the sheet.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum StripKind {
    /// The seed-phrase strip, to be destroyed once the shares are made.
    Seed,
    /// One of the three share strips.
    Share(ShareIndex),
}

impl StripKind {
    /// The four strips in page order, top to bottom.
    pub const ALL: [StripKind; 4] = [
        StripKind::Seed,
        StripKind::Share(ShareIndex::ONE),
        StripKind::Share(ShareIndex::TWO),
        StripKind::Share(ShareIndex::THREE),
    ];

    /// Position on the page, 0 at the top.
    pub fn slot(self) -> usize {
        match self {
            StripKind::Seed => 0,
            StripKind::Share(i) => usize::from(i.number()),
        }
    }

    /// The printed title.
    pub fn title(self) -> String {
        match self {
            StripKind::Seed => "Seed Phrase".to_owned(),
            StripKind::Share(i) => format!("Share {}", i.number()),
        }
    }

    /// The printed hint under the rows.
    pub fn hint(self) -> &'static str {
        match self {
            StripKind::Seed => "Destroy once done",
            StripKind::Share(ShareIndex::ONE) => "- Digital -",
            StripKind::Share(ShareIndex::TWO) => "- Social -",
            StripKind::Share(_) => "- Legal -",
        }
    }

    /// The identity code printed on the strip: six positions, a solid
    /// square where `true`. Pairwise Hamming distance 4 across the four
    /// kinds, so one obscured or spurious mark is corrected by
    /// [`StripKind::decode`] and two are detected.
    pub fn code(self) -> [bool; 6] {
        let bits = match self {
            StripKind::Seed => 0b000111,
            StripKind::Share(ShareIndex::ONE) => 0b110100,
            StripKind::Share(ShareIndex::TWO) => 0b011010,
            StripKind::Share(_) => 0b101001,
        };
        std::array::from_fn(|i| bits >> (5 - i) & 1 == 1)
    }

    /// The kind whose code is within Hamming distance 1 of `read`, if
    /// exactly one is; two or more mark errors give `None`.
    pub fn decode(read: [bool; 6]) -> Option<StripKind> {
        let mut near = StripKind::ALL
            .into_iter()
            .filter(|k| k.code().iter().zip(&read).filter(|(a, b)| a != b).count() <= 1);
        match (near.next(), near.next()) {
            (Some(k), None) => Some(k),
            _ => None,
        }
    }
}

impl fmt::Display for StripKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StripKind::Seed => f.write_str("seed phrase"),
            StripKind::Share(i) => write!(f, "share {i}"),
        }
    }
}

/// Which printed boxes a strip has: this worksheet's, grown for the pen,
/// or upstream's original, which the same cell centres serve.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Layout {
    /// This worksheet's boxes, 6.5 × 8 mm with dropout borders.
    Aided,
    /// Upstream's original boxes, 6.5 × 6.6 mm, a dotted line along the
    /// bottom of each row.
    Upstream,
}

impl Layout {
    /// Box extent along the strip.
    pub fn box_along(self) -> f64 {
        match self {
            Layout::Aided => Strip::BOX_ALONG,
            Layout::Upstream => Strip::UPSTREAM_BOX_ALONG,
        }
    }

    /// How far inside a box's edges a crop starts — top, right, bottom,
    /// left — so no printed border is in it: this worksheet's boxes have
    /// a border all round; upstream's have a dotted line along the bottom
    /// and nothing along the sides or top.
    pub fn crop_inset(self) -> [f64; 4] {
        match self {
            Layout::Aided => [0.6; 4],
            Layout::Upstream => [0.4, 0.5, 0.7, 0.5],
        }
    }

    /// How large a hand writes in the box, relative to this worksheet's.
    pub fn glyph_scale(self) -> f64 {
        match self {
            Layout::Aided => 1.0,
            Layout::Upstream => 0.9,
        }
    }

    /// Where word `word_index`'s symbol `position` (0..6) is written on a
    /// strip of this layout. Panics off the strip.
    pub fn cell_rect(self, word_index: usize, position: usize) -> Rect {
        let aided = Strip.cell_rect(word_index, position);
        let along = self.box_along();
        Rect {
            x: aided.x,
            y: aided.y + (Strip::BOX_ALONG - along) / 2.0,
            w: aided.w,
            h: along,
        }
    }
}

/// What a rendered strip carries beyond upstream's printing.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Aids {
    /// Fiducials, orientation mark, identity code, dropout borders.
    Full,
    /// Upstream's look: dotted boxes, shaded checksum boxes, separator
    /// lines, title, labels and hint, nothing for a camera.
    None,
}

/// One strip in its reading frame: `x` across, `y` along, origin at the
/// top-left corner of the cut border.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Strip;

impl Strip {
    /// Across, millimetres: upstream's band height.
    pub const WIDTH: f64 = Band::WIDTH;
    /// Along, millimetres: upstream's band length.
    pub const LENGTH: f64 = Band::LENGTH;
    /// Side of the corner fiducials.
    pub const FIDUCIAL: f64 = Band::FIDUCIAL;
    /// Fiducial inset from the cut border.
    pub const INSET: f64 = Band::INSET;
    /// Clearance kept free of other ink around fiducials and marks.
    pub const QUIET: f64 = Band::QUIET;
    /// Rows of words.
    pub const ROWS: usize = WORDS;
    /// Distance from the top to the first row's box.
    pub const ROWS_TOP: f64 = Band::ROWS_TOP;
    /// Row pitch: upstream's column pitch.
    pub const ROW_PITCH: f64 = Band::ROW_PITCH;
    /// Box extent along the strip.
    pub const BOX_ALONG: f64 = Band::ROW_HEIGHT;
    /// Upstream's box extent along the strip, as printed today.
    pub const UPSTREAM_BOX_ALONG: f64 = 6.6;
    /// Box extent across the strip: upstream's box pitch, borders inside.
    pub const BOX_ACROSS: f64 = Band::ROW_WIDTH / WORD_LEN as f64;
    /// Distance from the left cut border to the first box.
    pub const BOXES_LEFT: f64 = Band::ROW_LEFT;
    /// Side of the identity-code squares.
    pub const CODE_SQUARE: f64 = 3.0;

    /// Where the strip's fiducials, orientation mark and mark field are,
    /// for finding it in a photo: a band's.
    pub fn geometry(&self) -> Geometry {
        Band.geometry()
    }

    /// The whole strip.
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

    /// The sixteen mark-field slots; slot `i` carries bit `i` of the
    /// printed field. docs/marks.md records the convention.
    pub fn mark_slots(&self) -> [Rect; 16] {
        Band.mark_slots()
    }

    /// The six identity-code positions, left to right, below the rows.
    pub fn code_positions(&self) -> [Rect; 6] {
        std::array::from_fn(|i| Rect {
            x: 8.0 + 6.0 * i as f64,
            y: 148.5,
            w: Strip::CODE_SQUARE,
            h: Strip::CODE_SQUARE,
        })
    }

    /// Where word `word_index`'s symbol `position` (0..6) is written.
    /// Panics off the strip.
    pub fn cell_rect(&self, word_index: usize, position: usize) -> Rect {
        assert!(
            word_index < Strip::ROWS,
            "word {word_index} is off the strip"
        );
        assert!(position < WORD_LEN, "position {position} is not a box");
        Rect {
            x: Strip::BOXES_LEFT + Strip::BOX_ACROSS * position as f64,
            y: Strip::ROWS_TOP + Strip::ROW_PITCH * word_index as f64,
            w: Strip::BOX_ACROSS,
            h: Strip::BOX_ALONG,
        }
    }

    /// Centre of the row number left of the boxes.
    pub fn label_center(&self, word_index: usize) -> (f64, f64) {
        Band.label_center(word_index)
    }

    /// Centre of the title.
    pub fn title_center(&self) -> (f64, f64) {
        Band.title_center()
    }

    /// Centre of the hint.
    pub fn hint_center(&self) -> (f64, f64) {
        Band.hint_center()
    }
}

/// The page: where each strip's band is on the front, and where its panel
/// is on the back.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Sheet;

impl Sheet {
    /// Left edge of every front band.
    pub const BAND_X: f64 = BandPage::BAND_X;
    /// Top of the first band.
    pub const BAND_TOP: f64 = BandPage::BAND_TOP;
    /// Band pitch down the page.
    pub const BAND_PITCH: f64 = BandPage::BAND_PITCH;

    /// The band the strip in `slot` occupies on the front, page
    /// millimetres.
    pub fn band(&self, slot: usize) -> Rect {
        BandPage.band(slot)
    }

    /// A point in a strip's reading frame on the front page.
    pub fn to_page(&self, slot: usize, x: f64, y: f64) -> (f64, f64) {
        BandPage.to_page(slot, x, y)
    }

    /// A rectangle in a strip's reading frame on the front page.
    pub fn rect_to_page(&self, slot: usize, r: Rect) -> Rect {
        BandPage.rect_to_page(slot, r)
    }

    /// Where a rectangle of the front lands on the back after a long-edge
    /// duplex flip.
    pub fn flipped(&self, r: Rect) -> Rect {
        BandPage.flipped(r)
    }

    /// The back panel of `slot`, in the back page's own coordinates.
    pub fn back_panel(&self, slot: usize) -> BackPanel {
        BandPage.back_panel(slot)
    }
}

/// The static recovery QR as upstream prints it (rotated with the rest
/// of the panel), sampled from the vendored PDF: `v1.penlock.io/recover`.
pub const QR_MODULES: usize = 29;
/// Row-major, `#` dark.
pub const QR_GRID: [&str; QR_MODULES] = [
    "#######.#..#####..#....#..##.",
    "#.....#.##...#...#..#..#.##..",
    "#.###.#.###..###.#.##.....##.",
    "#.###.#....#.#..#.#####.#..##",
    "#.###.#.####.#...########.#.#",
    "#.....#..###.#.###..#...##...",
    "#######....###......#.#.#...#",
    "........#..#........#...####.",
    "..#####.....#...#..######...#",
    ".#.##....#....#####...###.#.#",
    ".##.#.#..##..#.....#.#....###",
    "##.###..#..#.##..#..#.##..#.#",
    "......#.#......#..##.######..",
    "##.##...#..#..#.#..#..#.#..#.",
    "####.########.##..#......##..",
    "###.##..#...#..#..#######..##",
    ".#....#.#####.#.#..##..##...#",
    "##.....#...#..####..##.##...#",
    "..###.#####.#.#...#.#...##..#",
    "#.#....#...#..#.#....###..#.#",
    "###.#.#.##...##....#.#####..#",
    "........#..#####...##........",
    "#######.#.#.#.#.#.#.#.#######",
    "#.....#.####..###.#.#.#.....#",
    "#.###.#.#.##.#.##.#...#.###.#",
    "#.###.#.#.##.###..#.#.#.###.#",
    "#.###.#...####.#.#....#.###.#",
    "#.....#..#.##.##..###.#.....#",
    "#######.##.....######.#######",
];

/// What a harness writes onto a sheet in place of a pen: the seed phrase
/// and any shares. **A fixture that puts secrets in a file**, which the
/// production `penlock sheet` cannot do.
#[derive(Clone, Debug)]
pub struct Fill<'a> {
    seed: Option<&'a [Word]>,
    shares: Vec<&'a Share>,
    font: Font,
    jitter: Option<(Jitter, u64)>,
}

/// Why a fill is refused.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FillError {
    /// A phrase or share without [`WORDS`] words.
    WordCount(usize),
    /// Two shares with the same index.
    Duplicate(ShareIndex),
}

impl fmt::Display for FillError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::WordCount(n) => write!(f, "a strip holds {WORDS} words, not {n}"),
            Self::Duplicate(i) => write!(f, "share {i} given twice"),
        }
    }
}

impl std::error::Error for FillError {}

impl<'a> Fill<'a> {
    /// Writes `seed` (if given) on the seed strip and each share on its
    /// own strip.
    pub fn new(
        seed: Option<&'a [Word]>,
        shares: &[&'a Share],
        font: Font,
    ) -> Result<Fill<'a>, FillError> {
        if let Some(n) = seed.map(<[Word]>::len).filter(|&n| n != WORDS) {
            return Err(FillError::WordCount(n));
        }
        let mut seen = Vec::new();
        for share in shares {
            if share.words().len() != WORDS {
                return Err(FillError::WordCount(share.words().len()));
            }
            if seen.contains(&share.index()) {
                return Err(FillError::Duplicate(share.index()));
            }
            seen.push(share.index());
        }
        Ok(Fill {
            seed,
            shares: shares.to_vec(),
            font,
            jitter: None,
        })
    }

    /// Perturbs every symbol's placement by up to `jitter`, drawn from
    /// `seed`.
    pub fn with_jitter(mut self, jitter: Jitter, seed: u64) -> Fill<'a> {
        self.jitter = Some((jitter, seed));
        self
    }

    /// The symbols written on `kind`'s strip, if any.
    pub fn symbols(&self, kind: StripKind) -> Option<Vec<[Symbol; WORD_LEN]>> {
        match kind {
            StripKind::Seed => self.seed.map(|w| w.iter().map(|w| w.symbols()).collect()),
            StripKind::Share(i) => self
                .shares
                .iter()
                .find(|s| s.index() == i)
                .map(|s| s.words().to_vec()),
        }
    }

    /// The font.
    pub fn font(&self) -> Font {
        self.font
    }
}

/// The SVG elements of one strip in its reading frame, blank or with
/// `fill`'s symbols for its kind, without the `<svg>` wrapper.
pub fn strip_group(kind: StripKind, fill: Option<&Fill<'_>>, rng_seed: u64) -> String {
    strip_group_with(kind, fill, rng_seed, Aids::Full)
}

/// One strip's SVG group with or without the scan aids.
pub fn strip_group_with(
    kind: StripKind,
    fill: Option<&Fill<'_>>,
    rng_seed: u64,
    aids: Aids,
) -> String {
    let mut s = String::new();
    Band.draw_border(&mut s);
    match aids {
        Aids::Full => {
            let share = match kind {
                StripKind::Seed => 0,
                StripKind::Share(i) => i.number(),
            };
            Band.draw_aids(&mut s, crate::marks::encode(share));
        }
        Aids::None => {
            for after in [3, 6, 9] {
                let y = Strip::ROWS_TOP + Strip::ROW_PITCH * after as f64 - 1.0;
                s.push_str(&format!(
                    "<line x1=\"4\" y1=\"{y:.2}\" x2=\"{:.2}\" y2=\"{y:.2}\" stroke=\"{TEXT}\" stroke-width=\"0.3\"/>\n",
                    Strip::WIDTH - 4.0
                ));
            }
        }
    }
    let layout = match aids {
        Aids::Full => Layout::Aided,
        Aids::None => Layout::Upstream,
    };
    let (title, hint) = match aids {
        Aids::Full => (kind.title(), kind.hint().to_owned()),
        Aids::None => (kind.title().to_uppercase(), kind.hint().to_lowercase()),
    };
    Band.draw_title(&mut s, &title);
    Band.draw_hint(&mut s, &hint);
    for word_index in 0..Strip::ROWS {
        Band.draw_label(&mut s, word_index);
        for position in 0..WORD_LEN {
            let cell = layout.cell_rect(word_index, position);
            let style = match (aids, position < 2) {
                (Aids::Full, true) => {
                    format!("fill=\"{CHECKSUM_FILL}\" stroke=\"{GUIDE}\" stroke-width=\"0.3\"")
                }
                (Aids::Full, false) => {
                    format!("fill=\"#ffffff\" stroke=\"{GUIDE}\" stroke-width=\"0.3\"")
                }
                (Aids::None, true) => format!("fill=\"{UPSTREAM_CHECKSUM_FILL}\""),
                (Aids::None, false) => String::new(),
            };
            if !style.is_empty() {
                rect(&mut s, cell, &style);
            }
        }
        if aids == Aids::None {
            // Upstream marks a row's boxes with a dotted line along the
            // bottom and a short tick rising at each border.
            let first = layout.cell_rect(word_index, 0);
            let last = layout.cell_rect(word_index, WORD_LEN - 1);
            let bottom = first.y + first.h;
            let dotted = format!(
                "stroke=\"{INK}\" stroke-width=\"0.25\" stroke-dasharray=\"0.3 0.3\" fill=\"none\""
            );
            s.push_str(&format!(
                "<line x1=\"{:.2}\" y1=\"{bottom:.2}\" x2=\"{:.2}\" y2=\"{bottom:.2}\" {dotted}/>\n",
                first.x,
                last.x + last.w
            ));
            for position in 0..=WORD_LEN {
                let x = first.x + Strip::BOX_ACROSS * position as f64;
                s.push_str(&format!(
                    "<line x1=\"{x:.2}\" y1=\"{:.2}\" x2=\"{x:.2}\" y2=\"{bottom:.2}\" {dotted}/>\n",
                    bottom - first.h / 3.0
                ));
            }
        }
    }
    if let Some(symbols) = fill.and_then(|f| f.symbols(kind)) {
        let fill = fill.expect("symbols came from it");
        let mut rng = fill
            .jitter
            .map(|(jitter, seed)| (jitter, rand::rngs::StdRng::seed_from_u64(seed ^ rng_seed)));
        for (word_index, row) in symbols.iter().enumerate() {
            for (position, symbol) in row.iter().enumerate() {
                let (cx, cy) = layout.cell_rect(word_index, position).center();
                // A hand writes to the box it is given.
                let font_size = CELL_FONT_SIZE * layout.glyph_scale();
                let (dx, dy, size, angle) = match &mut rng {
                    Some((j, rng)) => (
                        rng.random_range(-j.offset_mm..=j.offset_mm),
                        rng.random_range(-j.offset_mm..=j.offset_mm),
                        font_size * (1.0 + rng.random_range(-j.size..=j.size)),
                        rng.random_range(-j.rotation_deg..=j.rotation_deg),
                    ),
                    None => (0.0, 0.0, font_size, 0.0),
                };
                let glyph = text(
                    cx + dx,
                    cy + dy,
                    size,
                    "middle",
                    fill.font.family(),
                    INK,
                    &symbol.to_char().to_string(),
                );
                if angle == 0.0 {
                    s.push_str(&glyph);
                } else {
                    s.push_str(&format!(
                        "<g transform=\"rotate({angle:.2} {:.2} {:.2})\">{glyph}</g>\n",
                        cx + dx,
                        cy + dy
                    ));
                }
            }
        }
    }
    s
}

/// The front page as a self-contained SVG, blank or filled.
pub fn front_svg(fill: Option<&Fill<'_>>) -> Result<String, RenderError> {
    front_svg_with(fill, Aids::Full)
}

/// The front with or without the scan aids.
pub fn front_svg_with(fill: Option<&Fill<'_>>, aids: Aids) -> Result<String, RenderError> {
    let mut body = format!(
        "<rect width=\"{}\" height=\"{}\" fill=\"#ffffff\"/>\n",
        PAGE.0, PAGE.1
    );
    for kind in StripKind::ALL {
        body.push_str(&BandPage.place(
            kind.slot(),
            &strip_group_with(kind, fill, kind.slot() as u64, aids),
        ));
    }
    flatten(&svg_document(PAGE.0, PAGE.1, &body), PAGE.0, PAGE.1)
}

/// The back page as a self-contained SVG: upstream's panels, laid out for
/// a long-edge flip.
pub fn back_svg() -> Result<String, RenderError> {
    let mut body = format!(
        "<rect width=\"{}\" height=\"{}\" fill=\"#ffffff\"/>\n",
        PAGE.0, PAGE.1
    );
    let modules: Vec<Vec<bool>> = QR_GRID
        .iter()
        .map(|row| row.chars().map(|c| c == '#').collect())
        .collect();
    for kind in StripKind::ALL {
        BandPage.draw_back_panel(
            &mut body,
            kind.slot(),
            "Recovery",
            "v1.penlock.io/recover",
            &modules,
        );
    }
    flatten(&svg_document(PAGE.0, PAGE.1, &body), PAGE.0, PAGE.1)
}

/// How a pair of scissors missed the printed border, in millimetres per
/// side of the strip's reading frame: positive keeps that much paper
/// beyond the border, negative loses that much of the strip.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Cut {
    /// Along the strip's top edge.
    pub top: f64,
    /// Along its right edge.
    pub right: f64,
    /// Along its bottom edge.
    pub bottom: f64,
    /// Along its left edge.
    pub left: f64,
}

impl Cut {
    /// Cut exactly along the border.
    pub const EXACT: Cut = Cut {
        top: 0.0,
        right: 0.0,
        bottom: 0.0,
        left: 0.0,
    };

    /// Every side missed by up to `within` millimetres either way.
    pub fn random<R: RngCore>(rng: &mut R, within: f64) -> Cut {
        let mut side = || rng.random_range(-within..=within);
        Cut {
            top: side(),
            right: side(),
            bottom: side(),
            left: side(),
        }
    }
}

/// The strip in `slot` cut from a front page rendered at `dpi` and turned
/// to its reading frame: what a photo of one cut strip shows.
pub fn cut_strip(front: &RgbImage, dpi: f64, slot: usize) -> RgbImage {
    cut_strip_with(front, dpi, slot, Cut::EXACT)
}

/// The paper left after cutting the strip in `slot` with `cut`, turned to
/// its reading frame: `Strip::WIDTH + left + right` by `Strip::LENGTH +
/// top + bottom` millimetres at `dpi`, the printed border's corner at
/// `(left, top)`. Paper beyond the border shows what the sheet prints
/// there; a cut past the page edge stops at the page.
pub fn cut_strip_with(front: &RgbImage, dpi: f64, slot: usize, cut: Cut) -> RgbImage {
    let ppm = dpi / 25.4;
    let band = Sheet.band(slot);
    let x0 = (band.x - cut.top).max(0.0);
    let y0 = (band.y - cut.right).max(0.0);
    let x1 = (band.x + band.w + cut.bottom).min(PAGE.0);
    let y1 = (band.y + band.h + cut.left).min(PAGE.1);
    let px = |mm: f64| (mm * ppm).round() as u32;
    let band_image =
        image::imageops::crop_imm(front, px(x0), px(y0), px(x1 - x0), px(y1 - y0)).to_image();
    image::imageops::rotate90(&band_image)
}

/// The blank worksheet as a two-page PDF, front then back, A4 at actual
/// size.
#[cfg(feature = "print")]
pub fn sheet_pdf() -> Result<Vec<u8>, RenderError> {
    bitcoin_vision_forms::pdf::document(&[&front_svg(None)?, &back_svg()?], PAGE)
}

/// Renders the front at `dpi`, blank or filled.
pub fn front_png(fill: Option<&Fill<'_>>, dpi: f64) -> Result<RgbImage, RenderError> {
    front_png_with(fill, dpi, Aids::Full)
}

/// Renders the front at `dpi` with or without the scan aids.
pub fn front_png_with(
    fill: Option<&Fill<'_>>,
    dpi: f64,
    aids: Aids,
) -> Result<RgbImage, RenderError> {
    rasterize(&front_svg_with(fill, aids)?, dpi)
}

/// A share's rows as written on a strip, for display.
pub fn strip_rows(symbols: &[[Symbol; WORD_LEN]]) -> Vec<String> {
    symbols.iter().map(|w| symbols_to_string(*w)).collect()
}
