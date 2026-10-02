//! Consumer entry point; decoding and result projection do not change inference.

use crate::{
    detect::Detector,
    phrase::{PageScan, Reader},
    recogniser::Recogniser,
};
use std::sync::Arc;

use bitcoin_vision_core::scan::{Delta, Emitter, Outcome, Pipeline, ScanState};
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

/// Provenance of the canonical photo's top, separate from its pixel transform.
/// An identity EXIF transform alone does not establish that the writing is up.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PhotoUp {
    /// Legacy caller, stored raster, or missing metadata.
    #[default]
    Unknown,
    /// Capture-time camera metadata, including rotation zero.
    Camera,
    /// Valid file EXIF orientation, including orientation 1.
    Exif,
    /// Caller explicitly declares the canonical pixels upright.
    Explicit,
}

impl PhotoUp {
    /// Stable provenance name for diagnostics.
    pub fn source(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Camera => "camera",
            Self::Exif => "exif",
            Self::Explicit => "explicit",
        }
    }

    /// Whether the caller supplied evidence of photo-up.
    pub fn known(self) -> bool {
        self != Self::Unknown
    }
}

/// Per-call settings. Options never alter crop padding or vocabulary selection.
#[derive(Clone, Copy, Debug, Default)]
pub struct ScanOptions {
    /// Retain detailed processing decisions in the result (may contain text).
    pub diagnostics: bool,
    /// Independent evidence that the supplied decoded image is upright.
    pub photo_up: PhotoUp,
    /// Explicit EXIF transform (1..=8), overriding embedded metadata. Use1
    /// when a caller already normalized the pixels. None reads embedded EXIF.
    /// This option applies only to encoded image input, never `scan_rgb`.
    pub orientation: Option<u8>,
    /// Whether to look for a recovery phrase sheet before reading a page.
    pub layout: Layout,
    /// Which word-extent arm a page is read with. Research comparisons only;
    /// every other build reads with the arm the app ships.
    #[cfg(feature = "extent-experiment")]
    pub extent: Extent,
}

/// A word-extent arm to read a page with, for comparing them.
#[cfg(feature = "extent-experiment")]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Extent {
    /// The arm the app ships.
    #[default]
    Shipped,
    /// The historical baseline, before extents.
    Baseline,
    /// E3, returning its report, with component evidence when audited.
    E3(crate::extent::Audit),
}

/// A model-loading, image-decoding or scan-processing error.
#[derive(Clone, Debug)]
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
#[derive(Clone, Debug)]
pub struct ScanResult {
    /// Whether the photo was read as a page or as a sheet.
    pub found: Found,
    /// The E3 arm's report, when the scan was asked to read with it.
    #[cfg(feature = "extent-experiment")]
    pub extent: Option<Arc<crate::extent::Report>>,
    /// Observations, exact recognition crops, candidates and label evidence.
    #[cfg(feature = "research")]
    pub page: PageScan,
    #[cfg(not(feature = "research"))]
    pub(crate) page: PageScan,
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

    /// Prepare one synthetic crop for the opt-in timing harness.
    #[cfg(feature = "scan-profile")]
    pub fn profile_blank_ocr(&self, width: u32) -> Result<(), ScanError> {
        self.recogniser
            .profile_blank_width(width)
            .map_err(ScanError::Model)
    }

    /// A scanner over models the caller already built, for a caller that
    /// loads them its own way: the phone prepares its recogniser for its
    /// hardware, the research harness picks its own files.
    #[cfg(feature = "research")]
    pub fn from_models(detector: Detector, reader: Reader, recogniser: Recogniser) -> Self {
        Self {
            detector,
            reader,
            recogniser,
        }
    }

    /// Loads the complete model set, validating the classifier calibration.
    pub fn new(models: ModelBytes<'_>) -> Result<Self, ScanError> {
        Self::load(models, crate::recogniser::Preparation::default())
    }

    /// Opt-in comparison of recogniser preparation, without exposing its stage.
    #[cfg(feature = "scan-profile")]
    pub fn new_with_preparation(
        models: ModelBytes<'_>,
        preparation: crate::recogniser::Preparation,
    ) -> Result<Self, ScanError> {
        Self::load(models, preparation)
    }

    fn load(
        models: ModelBytes<'_>,
        preparation: crate::recogniser::Preparation,
    ) -> Result<Self, ScanError> {
        Ok(Self {
            detector: Detector::from_bytes(models.detector).map_err(ScanError::Model)?,
            reader: Reader::from_bytes(models.classifier, models.calibration)
                .map_err(ScanError::Model)?,
            recogniser: Recogniser::from_bytes_with_preparation(
                models.recogniser,
                models.dictionary,
                preparation,
            )
            .map_err(ScanError::Model)?,
        })
    }

    /// Scans decoded RGB pixels in their canonical orientation, to the end.
    /// Returned boxes are in this image's pixel coordinates; no implicit
    /// scaling or padding.
    pub fn scan_rgb(
        &self,
        image: &RgbImage,
        options: ScanOptions,
    ) -> Result<ScanResult, ScanError> {
        let (scan, _) = self.start(image.clone(), options);
        match scan.run() {
            Outcome::Finished(result) => {
                Ok(Arc::try_unwrap(result).unwrap_or_else(|r| (*r).clone()))
            }
            Outcome::Failed(error) => Err(error),
            Outcome::Cancelled | Outcome::Abandoned => {
                unreachable!("nothing else holds this scan's state, and it ran to its end")
            }
        }
    }

    /// Decodes JPEG, PNG or WebP and applies EXIF orientation exactly once,
    /// then scans to the end. Limits: 64 MiB encoded input, 40 million
    /// decoded pixels, decoder allocation limit 512 MiB (best-effort codec
    /// support). Does not resize accepted images.
    pub fn scan(&self, encoded: &[u8], options: ScanOptions) -> Result<ScanResult, ScanError> {
        let image = decode_image(encoded, options.orientation)?;
        self.scan_rgb(&image, options)
    }

    /// A scan of `photo`, not yet run, and a view of it for any thread.
    /// Run the [`Scan`] on a thread of the caller's choosing; poll or
    /// snapshot the [`ScanState`] from anywhere, while it runs or after.
    pub fn start(&self, photo: RgbImage, options: ScanOptions) -> (Scan<'_>, ScanState<Words>) {
        let (emitter, state) = bitcoin_vision_core::scan::record();
        (
            Scan {
                scanner: self,
                photo,
                options,
                emitter,
            },
            state,
        )
    }
}

/// How a scan decides what the photo shows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Layout {
    /// Look for a recovery phrase sheet by its marks; read a page of words if
    /// there is none.
    #[default]
    Auto,
    /// A page of words: do not look for a sheet.
    Page,
    /// A recovery phrase sheet: fail if none is found.
    Sheet,
}

/// What the photo turned out to be.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Found {
    /// A page of words, read by finding them.
    Page,
    /// A recovery phrase sheet, read field by field.
    Sheet,
}

/// The word pipeline's side of the scan protocol.
#[derive(Debug)]
pub struct Words;

/// One region as a scan knows it at a moment.
#[derive(Clone, Debug, PartialEq)]
pub struct WordRegion {
    /// Where it is, in the photo's canonical pixels.
    pub quad: [(f32, f32); 4],
    /// How far its reading has got.
    pub state: crate::progress::RegionState,
    /// What it was provisionally read as, once read. Word text.
    pub reading: Option<crate::progress::Reading>,
}

impl Pipeline for Words {
    type Phase = crate::progress::Phase;
    type Region = WordRegion;
    type Output = ScanResult;
    type Error = ScanError;
}

/// One scan of one photo, ready to run. See [`Scanner::start`].
pub struct Scan<'a> {
    scanner: &'a Scanner,
    photo: RgbImage,
    options: ScanOptions,
    emitter: Emitter<Words>,
}

impl Scan<'_> {
    /// Runs the scan to its end on this thread and returns how it ended,
    /// which is also the last thing its [`ScanState`] records.
    pub fn run(self) -> Outcome<Words> {
        let _cancellable = self.emitter.cancellation().enter();
        let recorder = Recorder(&self.emitter);
        let outcome: Outcome<Words> = match self.read(&recorder) {
            _ if self.emitter.cancel_requested() => Outcome::Cancelled,
            Ok(result) => Outcome::Finished(Arc::new(result)),
            Err(error) => Outcome::Failed(error),
        };
        let delta: Delta<Words> = match &outcome {
            Outcome::Finished(result) => Delta::Finished(Arc::clone(result)),
            Outcome::Failed(error) => Delta::Failed(error.clone()),
            Outcome::Cancelled => Delta::Cancelled,
            Outcome::Abandoned => unreachable!("run ends the scan itself"),
        };
        self.emitter
            .push(delta)
            .expect("only run ends the record, and it runs once");
        outcome
    }

    fn read(&self, recorder: &Recorder<'_>) -> Result<ScanResult, ScanError> {
        use crate::progress::{Event, Phase, emit, work};
        let observer: Option<&dyn crate::progress::Observer> = Some(recorder);
        let (photo, scanner) = (&self.photo, self.scanner);
        let stop = || {
            if self.emitter.cancel_requested() {
                Err(ScanError::Processing(
                    bitcoin_vision_core::scan::Cancelled.to_string(),
                ))
            } else {
                Ok(())
            }
        };
        work(observer, Phase::Preparing, 0, None);
        check_dimensions(photo.width(), photo.height())?;
        emit(observer, || Event::Photo {
            width: photo.width(),
            height: photo.height(),
        });
        let reader = scanner
            .reader
            .clone()
            .with_photo_up(self.options.photo_up)
            .with_decision_trace(self.options.diagnostics);
        stop()?;
        work(observer, Phase::Finding, 0, None);
        if self.options.layout != Layout::Page {
            let sheet = crate::wordsheet::read_observed(
                photo,
                &reader,
                Some(&scanner.recogniser),
                crate::phrase::CROP_MARGIN,
                observer,
            )
            .map_err(ScanError::Processing)?;
            match (sheet, self.options.layout) {
                (Some((page, regions)), _) => {
                    work(observer, Phase::Packing, 0, None);
                    return Ok(ScanResult {
                        found: Found::Sheet,
                        page,
                        regions,
                        #[cfg(feature = "extent-experiment")]
                        extent: None,
                    });
                }
                (None, Layout::Sheet) => {
                    return Err(ScanError::Processing(
                        "no recovery phrase sheet in the photo".into(),
                    ));
                }
                (None, _) => {}
            }
            stop()?;
        }
        let quads = scanner
            .detector
            .detect(photo)
            .map_err(ScanError::Processing)?;
        stop()?;
        let recogniser = &scanner.recogniser;
        let margin = crate::phrase::CROP_MARGIN;
        #[cfg(feature = "extent-experiment")]
        let (page, regions, extent) = match self.options.extent {
            Extent::Shipped => {
                let (page, regions) = crate::phrase::read_words_observed(
                    photo,
                    &quads,
                    &reader,
                    Some(recogniser),
                    margin,
                    observer,
                )
                .map_err(ScanError::Processing)?;
                (page, regions, None)
            }
            Extent::Baseline => {
                let (page, regions) = crate::phrase::read_words_baseline_observed(
                    photo,
                    &quads,
                    &reader,
                    Some(recogniser),
                    margin,
                    observer,
                )
                .map_err(ScanError::Processing)?;
                (page, regions, None)
            }
            Extent::E3(audit) => {
                let (experiment, regions) = crate::phrase::read_words_with_extent_e3_observed(
                    photo, &quads, &reader, recogniser, audit, observer,
                )
                .map_err(ScanError::Processing)?;
                (experiment.scan, regions, Some(Arc::new(experiment.report)))
            }
        };
        #[cfg(not(feature = "extent-experiment"))]
        let (page, regions) = crate::phrase::read_words_observed(
            photo,
            &quads,
            &reader,
            Some(recogniser),
            margin,
            observer,
        )
        .map_err(ScanError::Processing)?;
        work(observer, Phase::Packing, 0, None);
        Ok(ScanResult {
            found: Found::Page,
            page,
            regions,
            #[cfg(feature = "extent-experiment")]
            extent,
        })
    }
}

/// Carries the stages' progress into the scan's record.
struct Recorder<'a>(&'a Emitter<Words>);

impl crate::progress::Observer for Recorder<'_> {
    fn on_event(&self, event: crate::progress::Event) {
        use crate::progress::Event;
        let delta = match event {
            Event::Photo { width, height } => Delta::Photo { width, height },
            Event::Work {
                phase,
                completed,
                total,
            } => Delta::Work {
                phase,
                completed,
                total,
            },
            Event::Region(r) => Delta::Region {
                id: r.id,
                region: WordRegion {
                    quad: r.quad.0,
                    state: r.state,
                    reading: r.reading,
                },
            },
            Event::Replaced { region, parents } => Delta::Replaced {
                id: region.id,
                region: WordRegion {
                    quad: region.quad.0,
                    state: region.state,
                    reading: region.reading,
                },
                parents,
            },
            Event::Removed { id } => Delta::Removed { id },
            // The scan ends its own record, with its result or its error.
            Event::Finished { .. } | Event::Failed => return,
        };
        let _ = self.0.push(delta);
    }
}

/// The pixel-count limit every entry point applies, encoded or canonical.
/// Callers handing in their own decoded pixels admit them through here, so a
/// caller cannot reach past the limit by decoding an image themselves.
pub fn check_dimensions(width: u32, height: u32) -> Result<(), ScanError> {
    bitcoin_vision_core::check_dimensions(width, height).map_err(|e| ScanError::Image(e.0))
}

/// Decodes canonical RGB pixels with the same limits/orientation as [`Scanner::scan`].
/// Use this to display the exact coordinate frame associated with returned boxes.
pub fn decode_image(encoded: &[u8], orientation: Option<u8>) -> Result<RgbImage, ScanError> {
    bitcoin_vision_core::decode_image(encoded, orientation).map_err(|e| ScanError::Image(e.0))
}

// The models run against the bundled files, which every checkout carries; the
// cancellation contract is checked at each one's own entry point, which the
// shipped API does not expose.
#[cfg(all(test, feature = "onnx"))]
mod tests {
    use super::*;

    #[test]
    fn no_model_starts_inside_a_cancelled_scan() {
        use crate::detect::{Detector, Quad};
        use crate::phrase::{CROP_MARGIN, Reader, read_crop};
        use crate::recogniser::Recogniser;
        // Source-relative, so a copy of this file compiled elsewhere still
        // finds them.
        let detector =
            Detector::from_bytes(include_bytes!("../models/word-detector.onnx")).unwrap();
        let reader = Reader::from_bytes(
            include_bytes!("../models/word-reference.onnx"),
            include_str!("../models/word-reference.calibration"),
        )
        .unwrap();
        let recogniser = Recogniser::from_bytes(
            include_bytes!("../models/text-recogniser.onnx"),
            include_str!("../models/text-recogniser.dict.txt"),
        )
        .unwrap();
        let photo =
            decode_image(include_bytes!("../examples/photos/handwritten.png"), None).unwrap();
        let quad = Quad([(100., 100.), (400., 100.), (400., 180.), (100., 180.)]);
        let crop = image::DynamicImage::ImageRgb8(photo.clone())
            .crop_imm(100, 100, 300, 80)
            .into_luma8();

        let (emit, state) = bitcoin_vision_core::scan::record::<Words>();
        let _cancellable = emit.cancellation().enter();
        assert!(detector.detect(&photo).is_ok(), "runs before the cancel");
        state.cancel();
        let refused = |result: Result<(), String>| {
            assert_eq!(result.unwrap_err(), "scan cancelled");
        };
        refused(detector.detect(&photo).map(drop));
        refused(recogniser.read(&crop).map(drop));
        refused(read_crop(&photo, &quad, &reader, None, CROP_MARGIN).map(drop));
    }
}
