//! Admitting an image: the one set of limits both pipelines read under.
//!
//! Every entry point applies these, whether it is handed encoded bytes or its
//! own decoded pixels, so no caller can reach past the limit by decoding an
//! image itself.

use image::{ImageDecoder, RgbImage};

/// Why an image was not admitted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ImageError(pub String);

impl std::fmt::Display for ImageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ImageError {}

/// The pixel-count limit every entry point applies, encoded or canonical.
pub fn check_dimensions(width: u32, height: u32) -> Result<(), ImageError> {
    if width == 0 || height == 0 || u64::from(width) * u64::from(height) > 40_000_000 {
        return Err(ImageError(
            "image must contain 1..=40,000,000 pixels".into(),
        ));
    }
    Ok(())
}

/// Decodes canonical RGB pixels under the admission limits, applying the EXIF
/// orientation given or the one the image carries. The result is the frame
/// every coordinate a pipeline returns is in.
pub fn decode_image(encoded: &[u8], orientation: Option<u8>) -> Result<RgbImage, ImageError> {
    if encoded.len() > 64 * 1024 * 1024 {
        return Err(ImageError("encoded image exceeds64MiB".into()));
    }
    if orientation.is_some_and(|v| !(1..=8).contains(&v)) {
        return Err(ImageError(
            "orientation must be an EXIF transform in1..=8".into(),
        ));
    }
    let error = |e: image::ImageError| ImageError(e.to_string());
    let mut reader = image::ImageReader::new(std::io::Cursor::new(encoded))
        .with_guessed_format()
        .map_err(|e| ImageError(e.to_string()))?;
    reader.limits(image::Limits::default());
    let mut decoder = reader.into_decoder().map_err(error)?;
    let (width, height) = decoder.dimensions();
    check_dimensions(width, height)?;
    let orientation = match orientation {
        Some(n) => image::metadata::Orientation::from_exif(n).expect("validated EXIF"),
        None => decoder.orientation().map_err(error)?,
    };
    let mut image = image::DynamicImage::from_decoder(decoder).map_err(error)?;
    image.apply_orientation(orientation);
    Ok(image.into_rgb8())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dimensions_are_bounded_before_inference() {
        assert!(check_dimensions(0, 2).is_err());
        assert!(check_dimensions(40_000_001, 1).is_err());
        assert!(check_dimensions(u32::MAX, u32::MAX).is_err());
        assert!(check_dimensions(5000, 8000).is_ok());
    }
    #[test]
    fn all_exif_transforms_preserve_marker_coordinates() {
        let original = RgbImage::from_fn(3, 2, |x, y| image::Rgb([(1 + y * 3 + x) as u8, 0, 0]));
        let mut encoded = std::io::Cursor::new(Vec::new());
        original
            .write_to(&mut encoded, image::ImageFormat::Png)
            .unwrap();
        let expected: [&[u8]; 8] = [
            &[1, 2, 3, 4, 5, 6],
            &[3, 2, 1, 6, 5, 4],
            &[6, 5, 4, 3, 2, 1],
            &[4, 5, 6, 1, 2, 3],
            &[1, 4, 2, 5, 3, 6],
            &[4, 1, 5, 2, 6, 3],
            &[6, 3, 5, 2, 4, 1],
            &[3, 6, 2, 5, 1, 4],
        ];
        for n in 1..=8 {
            let decoded = decode_image(encoded.get_ref(), Some(n)).unwrap();
            assert_eq!(
                decoded.pixels().map(|p| p[0]).collect::<Vec<_>>(),
                expected[n as usize - 1]
            );
        }
        assert_eq!(decode_image(encoded.get_ref(), None).unwrap(), original);
        assert!(decode_image(encoded.get_ref(), Some(0)).is_err());
        assert!(decode_image(encoded.get_ref(), Some(9)).is_err());
        assert!(decode_image(b"invalid", None).is_err());
    }
}
