//! The Penlock band: a 51 × 171.3 mm card with twelve rows, found by its
//! corner squares and told apart by its mark field, laid four to an A4 page
//! on its side with a matching panel on the back. A Penlock share strip is
//! one, and so is the recovery phrase card; each says what its rows hold and
//! what id its mark field carries, and both look alike because this module
//! draws everything they share.
//!
//! Coordinates are millimetres in the band's reading frame: `x` across,
//! `y` along, origin at the top-left corner of the cut border.

use crate::frame::Geometry;
use crate::render::{GUIDE, INK, LABEL_FONT, Rect, TEXT, text};

/// Appends an SVG rectangle with the given presentation attributes.
pub fn rect(out: &mut String, r: Rect, style: &str) {
    out.push_str(&format!(
        "<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" {style}/>\n",
        r.x, r.y, r.w, r.h
    ));
}

/// One band in its reading frame.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Band;

impl Band {
    /// Across, millimetres: upstream's band height.
    pub const WIDTH: f64 = 51.0;
    /// Along, millimetres: upstream's band length.
    pub const LENGTH: f64 = 171.3;
    /// Side of the corner fiducials.
    pub const FIDUCIAL: f64 = 7.0;
    /// Fiducial inset from the cut border: room for scissors to drift
    /// without touching a fiducial.
    pub const INSET: f64 = 4.0;
    /// Clearance kept free of other ink around fiducials and marks.
    pub const QUIET: f64 = 2.0;
    /// Rows down the band.
    pub const ROWS: usize = 12;
    /// Distance from the top to the first row; upstream's first column, the
    /// box grown from 6.2 to 8 mm about its centre.
    pub const ROWS_TOP: f64 = 24.9;
    /// Row pitch: upstream's column pitch.
    pub const ROW_PITCH: f64 = 10.29;
    /// A row's extent along the band.
    pub const ROW_HEIGHT: f64 = 8.0;
    /// Distance from the left cut border to a row's start.
    pub const ROW_LEFT: f64 = 6.7;
    /// A row's extent across the band: upstream's six box pitches.
    pub const ROW_WIDTH: f64 = 6.0 * 6.5;

    /// Where the band's fiducials, orientation mark and mark field are, for
    /// finding it in a photo.
    pub fn geometry(&self) -> Geometry {
        Geometry {
            bounds: self.bounds(),
            fiducials: self.fiducials(),
            mark: self.mark(),
            mark_slots: self.mark_slots(),
        }
    }

    /// The whole band.
    pub fn bounds(&self) -> Rect {
        Rect {
            x: 0.0,
            y: 0.0,
            w: Band::WIDTH,
            h: Band::LENGTH,
        }
    }

    /// The four fiducials: top-left, top-right, bottom-left, bottom-right.
    pub fn fiducials(&self) -> [Rect; 4] {
        let far_x = Band::WIDTH - Band::INSET - Band::FIDUCIAL;
        let far_y = Band::LENGTH - Band::INSET - Band::FIDUCIAL;
        let at = |x, y| Rect {
            x,
            y,
            w: Band::FIDUCIAL,
            h: Band::FIDUCIAL,
        };
        [
            at(Band::INSET, Band::INSET),
            at(far_x, Band::INSET),
            at(Band::INSET, far_y),
            at(far_x, far_y),
        ]
    }

    /// The orientation mark beside the top-left fiducial.
    pub fn mark(&self) -> Rect {
        Rect {
            x: 15.5,
            y: 5.5,
            w: 4.0,
            h: 4.0,
        }
    }

    /// The sixteen mark-field slots: eight between the orientation mark and
    /// the top-right fiducial, eight between the bottom fiducials, left to
    /// right, [`Band::QUIET`] clear of the dark squares flanking them. Slot
    /// `i` carries bit `i` of the printed field.
    pub fn mark_slots(&self) -> [Rect; 16] {
        let side = 1.6;
        let row = |from: f64, to: f64, centre: f64, i: usize| Rect {
            x: from + (to - from - side) / 7.0 * i as f64,
            y: centre - side / 2.0,
            w: side,
            h: side,
        };
        let mark = self.mark();
        let [tl, tr, bl, br] = self.fiducials();
        std::array::from_fn(|i| {
            if i < 8 {
                row(
                    mark.x + mark.w + Band::QUIET,
                    tr.x - Band::QUIET - side,
                    tl.y + tl.h / 2.0,
                    i,
                )
            } else {
                row(
                    bl.x + bl.w + Band::QUIET,
                    br.x - Band::QUIET - side,
                    bl.y + bl.h / 2.0,
                    i - 8,
                )
            }
        })
    }

    /// Row `index`'s whole extent.
    pub fn row(&self, index: usize) -> Rect {
        assert!(index < Band::ROWS, "row {index} is off the band");
        Rect {
            x: Band::ROW_LEFT,
            y: Band::ROWS_TOP + Band::ROW_PITCH * index as f64,
            w: Band::ROW_WIDTH,
            h: Band::ROW_HEIGHT,
        }
    }

    /// Centre of row `index`'s number, left of the row.
    pub fn label_center(&self, index: usize) -> (f64, f64) {
        (
            Band::ROW_LEFT / 2.0,
            Band::ROWS_TOP + Band::ROW_PITCH * index as f64 + Band::ROW_HEIGHT / 2.0,
        )
    }

    /// Centre of the title.
    pub fn title_center(&self) -> (f64, f64) {
        (Band::WIDTH / 2.0 + 4.0, 17.5)
    }

    /// Centre of the label at the band's far end.
    pub fn hint_center(&self) -> (f64, f64) {
        (Band::WIDTH / 2.0, 156.0)
    }

    /// The white card and its dashed cut border.
    pub fn draw_border(&self, out: &mut String) {
        rect(out, self.bounds(), "fill=\"#ffffff\"");
        rect(
            out,
            self.bounds(),
            &format!(
                "fill=\"none\" stroke=\"{GUIDE}\" stroke-width=\"0.25\" stroke-dasharray=\"1.5 1\""
            ),
        );
    }

    /// The fiducials, the orientation mark and the mark field printing
    /// `field`.
    pub fn draw_aids(&self, out: &mut String, field: u16) {
        for f in self.fiducials() {
            rect(out, f, &format!("fill=\"{INK}\""));
        }
        rect(out, self.mark(), &format!("fill=\"{INK}\""));
        for (i, slot) in self.mark_slots().iter().enumerate() {
            // Empty slots print as outlined boxes: the field stays legible
            // to a human, and the light outline sits with the paper at every
            // ink threshold.
            if field >> i & 1 == 1 {
                rect(out, *slot, &format!("fill=\"{INK}\""));
            } else {
                rect(
                    out,
                    *slot,
                    &format!("fill=\"none\" stroke=\"{GUIDE}\" stroke-width=\"0.2\""),
                );
            }
        }
    }

    /// The title above the first row.
    pub fn draw_title(&self, out: &mut String, title: &str) {
        let (x, y) = self.title_center();
        out.push_str(&text(x, y, 5.0, "middle", LABEL_FONT, INK, title));
    }

    /// The label at the far end.
    pub fn draw_hint(&self, out: &mut String, hint: &str) {
        let (x, y) = self.hint_center();
        out.push_str(&text(x, y, 3.2, "middle", LABEL_FONT, TEXT, hint));
    }

    /// Row `index`'s number, `1.` for the first.
    pub fn draw_label(&self, out: &mut String, index: usize) {
        let (x, y) = self.label_center(index);
        out.push_str(&text(
            x,
            y,
            2.6,
            "middle",
            LABEL_FONT,
            TEXT,
            &format!("{}.", index + 1),
        ));
    }
}

/// An A4 page of bands: where each band sits on the front, and where its
/// panel sits on the back after a long-edge flip.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct BandPage;

impl BandPage {
    /// A4 portrait, millimetres.
    pub const PAGE: (f64, f64) = (210.0, 297.0);
    /// Bands on a page.
    pub const SLOTS: usize = 4;
    /// Left edge of every front band.
    pub const BAND_X: f64 = 17.0;
    /// Top of the first band.
    pub const BAND_TOP: f64 = 35.8;
    /// Band pitch down the page.
    pub const BAND_PITCH: f64 = 58.2;

    /// The band in `slot` on the front, page millimetres.
    pub fn band(&self, slot: usize) -> Rect {
        Rect {
            x: BandPage::BAND_X,
            y: BandPage::BAND_TOP + BandPage::BAND_PITCH * slot as f64,
            w: Band::LENGTH,
            h: Band::WIDTH,
        }
    }

    /// A point in a band's reading frame on the front page: the band is
    /// laid on its side, title to the left, rows read bottom to top.
    pub fn to_page(&self, slot: usize, x: f64, y: f64) -> (f64, f64) {
        let band = self.band(slot);
        (band.x + y, band.y + band.h - x)
    }

    /// A rectangle in a band's reading frame on the front page.
    pub fn rect_to_page(&self, slot: usize, r: Rect) -> Rect {
        let (x0, y1) = self.to_page(slot, r.x, r.y);
        let (x1, y0) = self.to_page(slot, r.x + r.w, r.y + r.h);
        Rect {
            x: x0,
            y: y0,
            w: x1 - x0,
            h: y1 - y0,
        }
    }

    /// Where a rectangle of the front lands on the back after a long-edge
    /// duplex flip: mirrored across the page's vertical centre line.
    pub fn flipped(&self, r: Rect) -> Rect {
        Rect {
            x: BandPage::PAGE.0 - r.x - r.w,
            ..r
        }
    }

    /// `group`, drawn in a band's reading frame, placed in `slot` on the
    /// front page.
    pub fn place(&self, slot: usize, group: &str) -> String {
        let band = self.band(slot);
        format!(
            "<g transform=\"translate({:.2} {:.2}) rotate(-90)\">\n{group}</g>\n",
            band.x,
            band.y + band.h
        )
    }

    /// The back panel of `slot`: upstream's date, wallet and owner boxes and
    /// the box holding the QR, in the back page's own coordinates (already
    /// mirrored, so it prints under its band after the flip). Upstream's
    /// panels run to within 0.3 mm of the band's edge; these stop 0.7 mm
    /// short so a slightly misregistered print still cuts clean.
    pub fn back_panel(&self, slot: usize) -> BackPanel {
        let y = BandPage::BAND_TOP + BandPage::BAND_PITCH * slot as f64 + 9.6;
        let h = 40.3;
        let at = |x, w| Rect { x, y, w, h };
        BackPanel {
            date: at(26.4, 9.5),
            wallet: at(41.2, 23.3),
            owner: at(70.0, 23.0),
            recovery: at(126.1, 40.9),
            qr: Rect {
                x: 131.2,
                y: y + 5.2,
                w: 30.7,
                h: 30.7,
            },
            title_x: 120.4,
            url_x: 171.8,
        }
    }

    /// Draws `slot`'s back panel: the three write-in boxes, the titled box
    /// holding the QR, the QR's `modules` (row-major, dark `true`), and the
    /// `url` they encode, printed under them.
    pub fn draw_back_panel(
        &self,
        out: &mut String,
        slot: usize,
        title: &str,
        url: &str,
        modules: &[Vec<bool>],
    ) {
        let panel = self.back_panel(slot);
        let dotted = format!(
            "fill=\"none\" stroke=\"{GUIDE}\" stroke-width=\"0.25\" stroke-dasharray=\"0.6 0.6\""
        );
        for r in [panel.date, panel.wallet, panel.owner, panel.recovery] {
            rect(out, r, &dotted);
        }
        let rotated = |x: f64, cy: f64, size: f64, anchor: &str, color: &str, body_text: &str| {
            format!(
                "<g transform=\"translate({x:.2} {cy:.2}) rotate(-90)\">{}</g>\n",
                text(0.0, 0.0, size, anchor, LABEL_FONT, color, body_text)
            )
        };
        for (r, label) in [
            (panel.date, "Date: __/__/__"),
            (panel.wallet, "Wallet:"),
            (panel.owner, "Owner:"),
        ] {
            out.push_str(&rotated(
                r.x + 3.0,
                r.y + r.h - 2.0,
                2.8,
                "start",
                INK,
                label,
            ));
        }
        out.push_str(&rotated(
            panel.title_x,
            panel.recovery.y + panel.recovery.h / 2.0,
            4.5,
            "middle",
            INK,
            title,
        ));
        out.push_str(&rotated(
            panel.url_x,
            panel.recovery.y + panel.recovery.h / 2.0,
            2.8,
            "middle",
            INK,
            url,
        ));
        let module = panel.qr.w / modules.len() as f64;
        for (j, row) in modules.iter().enumerate() {
            for (i, &dark) in row.iter().enumerate() {
                if dark {
                    rect(
                        out,
                        Rect {
                            x: panel.qr.x + i as f64 * module,
                            y: panel.qr.y + j as f64 * module,
                            w: module + 0.01,
                            h: module + 0.01,
                        },
                        &format!("fill=\"{INK}\""),
                    );
                }
            }
        }
    }
}

/// One band's back, page millimetres.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct BackPanel {
    /// `Date: __/__/__`.
    pub date: Rect,
    /// `Wallet:`.
    pub wallet: Rect,
    /// `Owner:`.
    pub owner: Rect,
    /// The titled box holding the QR.
    pub recovery: Rect,
    /// The QR itself.
    pub qr: Rect,
    /// Centre line of the rotated title.
    pub title_x: f64,
    /// Centre line of the rotated URL.
    pub url_x: f64,
}

impl BackPanel {
    /// Every rectangle of the panel.
    pub fn rects(&self) -> [Rect; 5] {
        [self.date, self.wallet, self.owner, self.recovery, self.qr]
    }
}
