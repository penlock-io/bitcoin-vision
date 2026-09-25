//! Consumer entry point; decoding and result projection do not change inference.

use crate::{
    detect::Detector,
    phrase::{PageScan, Reader},
    recogniser::Recogniser,
};
use image::RgbImage;

/// Borrowed artifacts used to create a reusable scanner. Loading copies no
/// photos and performs no downloads; model plans own their parsed weights.
pub struct ModelBytes<'a> {
    /// PP-OCR detector ONNX bytes.
    pub detector: &'a [u8],
    /// BIP39 classifier ONNX bytes.
    pub classifier: &'a [u8],
    /// Classifier-bound calibration text.
    pub calibration: &'a str,
    /// PP-OCR English recognition ONNX bytes.
    pub recogniser: &'a [u8],
    /// Recognition character dictionary, one entry per line.
    pub dictionary: &'a str,
}

/// Per-call settings. Options never alter crop padding or vocabulary selection.
#[derive(Clone, Copy, Debug, Default)]
pub struct ScanOptions {
    /// Retain detailed processing decisions in the result (may contain text).
    pub diagnostics: bool,
    /// Independent evidence that the supplied decoded image is upright.
    pub photo_up: crate::page_frame::PhotoUp,
    /// Explicit EXIF transform (1..=8), overriding embedded metadata. Use1
    /// when a caller already normalized the pixels. None reads embedded EXIF.
    /// This option applies only to encoded image input, never `scan_rgb`.
    pub orientation: Option<u8>,
}

/// A model-loading, image-decoding or scan-processing error.
#[derive(Debug)]
pub enum ScanError {
    /// A required artifact failed to load or did not match its contract.
    Model(String),
    /// Image input could not be decoded within the configured limits.
    Image(String),
    /// Geometry, inference or final-region validation failed.
    Processing(String),
}
impl std::fmt::Display for ScanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Model(e) => write!(f, "model: {e}"),
            Self::Image(e) => write!(f, "image: {e}"),
            Self::Processing(e) => write!(f, "scan: {e}"),
        }
    }
}
impl std::error::Error for ScanError {}

/// Native observations plus stage-owned final geometry and suggested order.
pub struct ScanResult {
    /// Observations, exact recognition crops, candidates and label evidence.
    pub page: PageScan,
    /// Final output regions, mapped to the page observations by the scanner.
    pub regions: Vec<crate::progress::FinalRegion>,
}

/// Reusable offline detector, classifier and text recogniser.
pub struct Scanner {
    detector: Detector,
    reader: Reader,
    recogniser: Recogniser,
}

impl Scanner {
    /// Loads the model files compiled into the optional Git-distributed bundle.
    #[cfg(feature = "bundled-models")]
    pub fn bundled() -> Result<Self, ScanError> {
        Self::new(ModelBytes {
            detector: include_bytes!("../models/word-detector.onnx"),
            classifier: include_bytes!("../models/word-reference.onnx"),
            calibration: include_str!("../models/word-reference.calibration"),
            recogniser: include_bytes!("../models/text-recogniser.onnx"),
            dictionary: include_str!("../models/text-recogniser.dict.txt"),
        })
    }
    /// Loads the complete model set, validating the classifier calibration.
    pub fn new(models: ModelBytes<'_>) -> Result<Self, ScanError> {
        Ok(Self {
            detector: Detector::from_bytes(models.detector).map_err(ScanError::Model)?,
            reader: Reader::from_bytes(models.classifier, models.calibration)
                .map_err(ScanError::Model)?,
            recogniser: Recogniser::from_bytes(models.recogniser, models.dictionary)
                .map_err(ScanError::Model)?,
        })
    }

    /// Scans decoded RGB pixels in their canonical orientation. Returned boxes
    /// are in this image's pixel coordinates; no implicit scaling or padding.
    pub fn scan_rgb(
        &self,
        image: &RgbImage,
        options: ScanOptions,
    ) -> Result<ScanResult, ScanError> {
        self.scan_rgb_observed(image, options, None)
    }

    /// Decodes JPEG, PNG or WebP and applies EXIF orientation exactly once.
    /// Limits:64MiB encoded input,40 million decoded pixels, decoder allocation
    /// limit512MiB (best-effort codec support). Does not resize accepted images.
    pub fn scan(&self, encoded: &[u8], options: ScanOptions) -> Result<ScanResult, ScanError> {
        let image = decode_image(encoded, options.orientation)?;
        self.scan_rgb(&image, options)
    }

    /// The same pipeline with optional synchronous progress observations.
    pub fn scan_rgb_observed(
        &self,
        image: &RgbImage,
        options: ScanOptions,
        observer: Option<&dyn crate::progress::Observer>,
    ) -> Result<ScanResult, ScanError> {
        use crate::progress::{Event, Phase, emit, work};
        // Region identity belongs to the result even when no UI subscribes.
        // The app/harness likewise keep the stage observer present for mapping.
        struct Ignore;
        impl crate::progress::Observer for Ignore {
            fn on_event(&self, _: Event) {}
        }
        let ignore = Ignore;
        let observer: Option<&dyn crate::progress::Observer> = Some(observer.unwrap_or(&ignore));
        work(observer, Phase::Preparing, 0, None);
        let result = (|| {
            check_dimensions(image.width(), image.height())?;
            emit(observer, || Event::Photo {
                width: image.width(),
                height: image.height(),
            });
            work(observer, Phase::Finding, 0, None);
            let quads = self.detector.detect(image).map_err(ScanError::Processing)?;
            let reader = self
                .reader
                .clone()
                .with_photo_up(options.photo_up)
                .with_decision_trace(options.diagnostics);
            let (page, regions) = crate::phrase::read_words_observed(
                image,
                &quads,
                &reader,
                Some(&self.recogniser),
                crate::phrase::CROP_MARGIN,
                observer,
            )
            .map_err(ScanError::Processing)?;
            work(observer, Phase::Packing, 0, None);
            Ok(ScanResult { page, regions })
        })();
        emit(observer, || match &result {
            Ok(r) => Event::Finished {
                regions: r.regions.clone(),
            },
            Err(_) => Event::Failed,
        });
        result
    }
}

/// The pixel-count limit every entry point applies, encoded or canonical.
/// Callers handing in their own decoded pixels — including the sibling Penlock
/// pipeline — admit them through here, so a caller cannot reach past the limit
/// by decoding an image themselves.
pub fn check_dimensions(width: u32, height: u32) -> Result<(), ScanError> {
    bitcoin_vision_core::check_dimensions(width, height).map_err(|e| ScanError::Image(e.0))
}

/// Decodes canonical RGB pixels with the same limits/orientation as [`Scanner::scan`].
/// Use this to display the exact coordinate frame associated with returned boxes.
pub fn decode_image(encoded: &[u8], orientation: Option<u8>) -> Result<RgbImage, ScanError> {
    bitcoin_vision_core::decode_image(encoded, orientation).map_err(|e| ScanError::Image(e.0))
}
