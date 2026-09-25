//! Printed forms, read and drawn: a form declares where its fiducials,
//! orientation mark and mark-field slots are, and this crate finds it in a
//! photo, rectifies it, and reads its field. It names no form; what a
//! field's bits mean is each form's business.
//!
//! Forms are authored as SVG in millimetres and rasterised here with the
//! bundled fonts, since reading one sometimes means rendering what it
//! should look like. Writing a form out as PDF is behind `print`.

#![deny(missing_docs)]

pub mod frame;
pub mod marks;
#[cfg(feature = "print")]
pub mod pdf;
pub mod render;

pub use frame::{Frame, FrameError, Geometry, RECTIFIED_PX_PER_MM, locate_frames, read_field};
pub use marks::Field;
pub use render::{Font, Jitter, Rect, RenderError, px_per_mm, rasterize};
