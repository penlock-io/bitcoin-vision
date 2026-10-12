//! A form's pages as one PDF, for printing at actual size.

use pdf_writer::types::{LineCapStyle, LineJoinStyle};
use pdf_writer::{Content, Filter, Finish, Pdf, Rect, Ref};
use resvg::tiny_skia::{PathSegment, Point};
use resvg::usvg::{self, FillRule, Node, Paint, PaintOrder};

use crate::render::RenderError;

const POINTS_PER_MM: f64 = 72.0 / 25.4;

/// A PDF with one page per SVG in `pages`, each `page_mm` wide and high,
/// the SVG scaled to fill it.
///
/// Every colour is written as DeviceGray, never RGB: a printer makes RGB
/// grey from its colour inks, so a printer low on colour printed the guides
/// almost invisibly, where DeviceGray prints from black alone. A page that
/// is not flat grey paths (a colour, a gradient, transparency, an image or
/// unflattened text) is refused rather than approximated.
pub fn document(pages: &[&str], page_mm: (f64, f64)) -> Result<Vec<u8>, RenderError> {
    let (width, height) = (
        (page_mm.0 * POINTS_PER_MM) as f32,
        (page_mm.1 * POINTS_PER_MM) as f32,
    );
    let catalog = Ref::new(1);
    let page_tree = Ref::new(2);
    let mut pdf = Pdf::new();
    let mut page_ids = Vec::with_capacity(pages.len());
    for (i, svg) in pages.iter().enumerate() {
        let tree = usvg::Tree::from_str(svg, &usvg::Options::default())
            .map_err(|e| RenderError::Svg(e.to_string()))?;
        let scale = width / tree.size().width();
        let mut content = Content::new();
        content.transform([scale, 0.0, 0.0, -scale, 0.0, height]);
        draw_group(&mut content, tree.root())?;
        let page_id = Ref::new(3 + 2 * i as i32);
        let content_id = Ref::new(4 + 2 * i as i32);
        page_ids.push(page_id);
        let mut page = pdf.page(page_id);
        page.media_box(Rect::new(0.0, 0.0, width, height));
        page.parent(page_tree);
        page.contents(content_id);
        page.finish();
        let compressed = miniz_oxide::deflate::compress_to_vec_zlib(&content.finish(), 6);
        pdf.stream(content_id, &compressed)
            .filter(Filter::FlateDecode);
    }
    pdf.catalog(catalog).pages(page_tree);
    pdf.pages(page_tree)
        .kids(page_ids.iter().copied())
        .count(page_ids.len() as i32);
    Ok(pdf.finish())
}

fn unsupported(what: &str) -> RenderError {
    RenderError::Svg(format!("a printed page cannot carry {what}"))
}

fn draw_group(content: &mut Content, group: &usvg::Group) -> Result<(), RenderError> {
    if group.opacity().get() != 1.0
        || group.clip_path().is_some()
        || group.mask().is_some()
        || !group.filters().is_empty()
        || group.blend_mode() != usvg::BlendMode::Normal
    {
        return Err(unsupported("transparency, clipping or effects"));
    }
    let t = group.transform();
    content.save_state();
    content.transform([t.sx, t.ky, t.kx, t.sy, t.tx, t.ty]);
    for node in group.children() {
        match node {
            Node::Group(g) => draw_group(content, g)?,
            Node::Path(p) => draw_path(content, p)?,
            Node::Image(_) => return Err(unsupported("an image")),
            Node::Text(_) => return Err(unsupported("unflattened text")),
        }
    }
    content.restore_state();
    Ok(())
}

/// The paint as a DeviceGray level, 0 black to 1 white.
fn gray(paint: &Paint, opacity: f32) -> Result<f32, RenderError> {
    match paint {
        Paint::Color(c) if c.red == c.green && c.green == c.blue && opacity == 1.0 => {
            Ok(f32::from(c.red) / 255.0)
        }
        Paint::Color(c) => Err(unsupported(&format!(
            "rgb({}, {}, {}) at opacity {opacity}: only opaque greys print from black ink",
            c.red, c.green, c.blue
        ))),
        _ => Err(unsupported("a gradient or pattern")),
    }
}

fn draw_path(content: &mut Content, path: &usvg::Path) -> Result<(), RenderError> {
    if !path.is_visible() {
        return Ok(());
    }
    let fill = path
        .fill()
        .map(|f| Ok::<_, RenderError>((gray(f.paint(), f.opacity().get())?, f.rule())))
        .transpose()?;
    if let Some((level, _)) = fill {
        content.set_fill_gray(level);
    }
    if let Some(stroke) = path.stroke() {
        content.set_stroke_gray(gray(stroke.paint(), stroke.opacity().get())?);
        content.set_line_width(stroke.width().get());
        content.set_miter_limit(stroke.miterlimit().get());
        content.set_line_cap(match stroke.linecap() {
            usvg::LineCap::Butt => LineCapStyle::ButtCap,
            usvg::LineCap::Round => LineCapStyle::RoundCap,
            usvg::LineCap::Square => LineCapStyle::ProjectingSquareCap,
        });
        content.set_line_join(match stroke.linejoin() {
            usvg::LineJoin::Miter | usvg::LineJoin::MiterClip => LineJoinStyle::MiterJoin,
            usvg::LineJoin::Round => LineJoinStyle::RoundJoin,
            usvg::LineJoin::Bevel => LineJoinStyle::BevelJoin,
        });
        content.set_dash_pattern(
            stroke.dasharray().unwrap_or(&[]).iter().copied(),
            stroke.dashoffset(),
        );
    }
    let even_odd = matches!(fill, Some((_, FillRule::EvenOdd)));
    let fill_then_stroke = path.paint_order() == PaintOrder::FillAndStroke;
    match (fill.is_some(), path.stroke().is_some()) {
        (true, true) if fill_then_stroke => {
            trace(content, path.data());
            if even_odd {
                content.fill_even_odd_and_stroke();
            } else {
                content.fill_nonzero_and_stroke();
            }
        }
        (true, true) => {
            trace(content, path.data());
            content.stroke();
            trace(content, path.data());
            fill_with(content, even_odd);
        }
        (true, false) => {
            trace(content, path.data());
            fill_with(content, even_odd);
        }
        (false, true) => {
            trace(content, path.data());
            content.stroke();
        }
        (false, false) => {}
    }
    Ok(())
}

fn fill_with(content: &mut Content, even_odd: bool) {
    if even_odd {
        content.fill_even_odd();
    } else {
        content.fill_nonzero();
    }
}

fn trace(content: &mut Content, data: &resvg::tiny_skia::Path) {
    let mut last = Point::zero();
    for segment in data.segments() {
        match segment {
            PathSegment::MoveTo(p) => {
                content.move_to(p.x, p.y);
                last = p;
            }
            PathSegment::LineTo(p) => {
                content.line_to(p.x, p.y);
                last = p;
            }
            PathSegment::QuadTo(c, p) => {
                // PDF has no quadratic curve; this is its exact cubic
                let c1 = (
                    last.x + 2.0 / 3.0 * (c.x - last.x),
                    last.y + 2.0 / 3.0 * (c.y - last.y),
                );
                let c2 = (p.x + 2.0 / 3.0 * (c.x - p.x), p.y + 2.0 / 3.0 * (c.y - p.y));
                content.cubic_to(c1.0, c1.1, c2.0, c2.1, p.x, p.y);
                last = p;
            }
            PathSegment::CubicTo(c1, c2, p) => {
                content.cubic_to(c1.x, c1.y, c2.x, c2.y, p.x, p.y);
                last = p;
            }
            PathSegment::Close => {
                content.close_path();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page(body: &str) -> String {
        crate::render::svg_document(10.0, 10.0, body)
    }

    fn content(pdf: &[u8]) -> String {
        let start = pdf.windows(7).position(|w| w == b"stream\n").unwrap() + 7;
        let end = start
            + pdf[start..]
                .windows(9)
                .position(|w| w == b"endstream")
                .unwrap();
        let raw = miniz_oxide::inflate::decompress_to_vec_zlib(&pdf[start..end]).unwrap();
        String::from_utf8(raw).unwrap()
    }

    #[test]
    fn greys_are_written_for_black_ink_alone() {
        let svg = page(
            "<rect width=\"5\" height=\"5\" fill=\"#c8c8c8\" stroke=\"#000000\" stroke-width=\"0.3\" stroke-dasharray=\"1 1\"/>",
        );
        let pdf = document(&[&svg], (10.0, 10.0)).unwrap();
        let ops = content(&pdf);
        assert!(ops.contains("0.78431374 g") && ops.contains("0 G"), "{ops}");
        assert!(ops.contains("[1 1] 0 d"), "{ops}");
        for rgb in [" rg", " RG", " sc", " SC", " cs", " CS"] {
            assert!(!ops.contains(rgb), "{rgb} in {ops}");
        }
        assert!(!pdf.windows(8).any(|w| w == b"ICCBased"));
    }

    #[test]
    fn anything_but_opaque_grey_is_refused() {
        for body in [
            "<rect width=\"5\" height=\"5\" fill=\"#c8c8c9\"/>",
            "<rect width=\"5\" height=\"5\" fill=\"#808080\" fill-opacity=\"0.5\"/>",
            "<g opacity=\"0.5\"><rect width=\"5\" height=\"5\"/></g>",
        ] {
            assert!(document(&[&page(body)], (10.0, 10.0)).is_err(), "{body}");
        }
    }
}
