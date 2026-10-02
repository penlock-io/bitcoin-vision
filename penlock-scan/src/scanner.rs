//! The pipeline's entry point, shaped like the word-list scanner's.
//!
//! The two pipelines in this repository answer the same kind of question — a
//! photograph in, structured data with per-item evidence out — so they are
//! loaded, called and read the same way. What differs between a word and a
//! cell belongs in the payload: a word has 2048 candidates and a reading
//! order, a cell has 29 and a share number.

use image::RgbImage;
use penlock::word::WORD_LEN;
use penlock::{Distribution, ShareIndex, Symbol};
use serde::Serialize;
use std::sync::Arc;

use bitcoin_vision_core::scan::{Delta, Emitter, Outcome, Pipeline, ScanState};

use crate::locate::{Identity, LocateError};
use crate::model::{Model, ModelError};
use crate::strip_scan::ScannedShare;

/// The model files a scanner needs, as bytes the caller owns.
pub struct ModelBytes<'a> {
    /// The 29-way cell classifier.
    pub cells: &'a [u8],
}

/// Per-call settings. Options never alter cell normalisation or the alphabet.
#[derive(Clone, Copy, Debug, Default)]
pub struct ScanOptions {
    /// Retain per-cell distributions in the projection, not only the reading.
    pub diagnostics: bool,
    /// Explicit EXIF transform (1..=8), overriding embedded metadata. Applies
    /// only to encoded input, never to `scan_rgb`.
    pub orientation: Option<u8>,
}

/// A model-loading, image-decoding or strip-locating error.
#[derive(Clone, Debug)]
pub enum ScanError {
    /// The classifier could not be loaded or failed on a cell.
    Model(ModelError),
    /// The bytes were not a decodable image, or exceeded a limit.
    Image(String),
    /// No strip could be found in the photograph.
    Locate(LocateError),
}

impl std::fmt::Display for ScanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Model(e) => write!(f, "model: {e}"),
            Self::Image(e) => write!(f, "image: {e}"),
            Self::Locate(e) => write!(f, "scan: {e}"),
        }
    }
}

impl std::error::Error for ScanError {}

impl From<crate::strip_scan::ReadError> for ScanError {
    fn from(error: crate::strip_scan::ReadError) -> Self {
        match error {
            crate::strip_scan::ReadError::Locate(e) => Self::Locate(e),
            crate::strip_scan::ReadError::Model(e) => Self::Model(e),
        }
    }
}

/// Reusable offline strip reader. A scanner is shared across threads, so a
/// model it holds must be too.
pub struct Scanner {
    model: Box<dyn Model + Send + Sync>,
}

impl Scanner {
    /// Loads the cell classifier compiled into the crate under
    /// `bundled-models`: `models/cell-reference.onnx`, and nothing else.
    #[cfg(feature = "bundled-models")]
    pub fn bundled() -> Result<Self, ScanError> {
        Self::new(ModelBytes {
            cells: include_bytes!("../models/cell-reference.onnx"),
        })
    }

    /// Loads the cell classifier from bytes the caller supplies. On a phone
    /// the model ships inside the app rather than at a filesystem path.
    #[cfg(feature = "onnx")]
    pub fn new(models: ModelBytes<'_>) -> Result<Self, ScanError> {
        let model = crate::model::Onnx::from_bytes(models.cells)
            .map_err(|message| ScanError::Model(ModelError::Unusable(message)))?;
        Ok(Self {
            model: Box::new(model),
        })
    }

    /// A scanner over an already-built model, for callers with their own.
    #[cfg(feature = "research")]
    pub fn from_model(model: Box<dyn Model + Send + Sync>) -> Self {
        Self { model }
    }

    /// Decodes JPEG, PNG or WebP and applies EXIF orientation exactly once,
    /// then reads the one strip in the photograph. Limits and decoding are the
    /// core's, so both pipelines read the same files the same way.
    pub fn scan(&self, encoded: &[u8], options: ScanOptions) -> Result<ScanResult, ScanError> {
        self.scan_rgb(&decode(encoded, options)?, options)
    }

    /// Reads the one strip in a photograph already in canonical orientation.
    pub fn scan_rgb(
        &self,
        image: &RgbImage,
        options: ScanOptions,
    ) -> Result<ScanResult, ScanError> {
        let (scan, _) = self.start(image.clone(), options);
        finish(scan.run())
    }

    /// Every strip in a photograph of an uncut sheet, in reading order.
    pub fn scan_all(&self, encoded: &[u8], options: ScanOptions) -> Result<ScanResult, ScanError> {
        self.scan_all_rgb(&decode(encoded, options)?, options)
    }

    /// Every strip in a canonical photograph of an uncut sheet.
    pub fn scan_all_rgb(
        &self,
        image: &RgbImage,
        options: ScanOptions,
    ) -> Result<ScanResult, ScanError> {
        let (scan, _) = self.start_all(image.clone(), options);
        finish(scan.run())
    }

    /// Prepares one canonical photo for a caller-driven scan. The caller runs
    /// `Scan::run` on its chosen thread and may poll the returned state before,
    /// during, or after it runs. Decoding and model loading stay outside it.
    pub fn start(&self, photo: RgbImage, options: ScanOptions) -> (Scan<'_>, ScanState<Strips>) {
        self.prepare(photo, options, false)
    }

    /// As `start`, reading every strip on an uncut sheet in reading order.
    pub fn start_all(
        &self,
        photo: RgbImage,
        options: ScanOptions,
    ) -> (Scan<'_>, ScanState<Strips>) {
        self.prepare(photo, options, true)
    }

    fn prepare(
        &self,
        photo: RgbImage,
        options: ScanOptions,
        all: bool,
    ) -> (Scan<'_>, ScanState<Strips>) {
        let (emitter, state) = bitcoin_vision_core::scan::record();
        (
            Scan {
                scanner: self,
                photo,
                options,
                all,
                emitter,
            },
            state,
        )
    }
}

fn finish(outcome: Outcome<Strips>) -> Result<ScanResult, ScanError> {
    match outcome {
        Outcome::Finished(result) => Ok(Arc::try_unwrap(result).unwrap_or_else(|r| (*r).clone())),
        Outcome::Failed(error) => Err(error),
        Outcome::Cancelled | Outcome::Abandoned => {
            unreachable!("a synchronous scan runs without an external cancellation handle")
        }
    }
}

/// The strip pipeline's stages, shared with the word scan protocol.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// Validate the decoded photo.
    Admitting,
    /// Locate strips in canonical photo pixels.
    Locating,
    /// Report each strip's format and identity.
    Identifying,
    /// Read the cells in each strip.
    Reading,
    /// Assemble the result.
    Packing,
}

/// What one located strip contributes to the retained scan state.
#[derive(Clone, Debug, PartialEq)]
pub struct StripRegion {
    /// Fiducial positions in canonical photo pixels.
    pub quad: [(f64, f64); 4],
    /// Identity obtained from the printed marks.
    pub identity: Identity,
    /// All cell probabilities, once read. `None` means location is known but
    /// inference has not completed.
    pub reading: Option<Reading>,
}

/// Cell evidence retained in a progress region after classification.
#[derive(Clone, Debug, PartialEq)]
pub struct Reading {
    /// One distribution per cell, grouped by worksheet row.
    pub cells: Vec<[Distribution; WORD_LEN]>,
    /// Cells with no usable classifier output.
    pub unread: Vec<(usize, usize)>,
}

/// The strip pipeline's implementation of the common scan protocol.
#[derive(Debug)]
pub struct Strips;

impl Pipeline for Strips {
    type Phase = Phase;
    type Region = StripRegion;
    type Output = ScanResult;
    type Error = ScanError;
}

/// A scan ready to run on the caller's thread.
pub struct Scan<'a> {
    scanner: &'a Scanner,
    photo: RgbImage,
    options: ScanOptions,
    all: bool,
    emitter: Emitter<Strips>,
}

impl Scan<'_> {
    /// Runs the scan and records exactly one terminal outcome.
    pub fn run(self) -> Outcome<Strips> {
        let _cancellable = self.emitter.cancellation().enter();
        let outcome: Outcome<Strips> = match self.read() {
            _ if self.emitter.cancel_requested() => Outcome::Cancelled,
            Ok(result) => Outcome::Finished(Arc::new(result)),
            Err(error) => Outcome::Failed(error),
        };
        let terminal: Delta<Strips> = match &outcome {
            Outcome::Finished(result) => Delta::Finished(result.clone()),
            Outcome::Failed(error) => Delta::Failed(error.clone()),
            Outcome::Cancelled => Delta::Cancelled,
            Outcome::Abandoned => unreachable!("run ends its own record"),
        };
        self.emitter
            .push(terminal)
            .expect("run owns the open record");
        outcome
    }

    fn read(&self) -> Result<ScanResult, ScanError> {
        let emit = &self.emitter;
        emit.push(Delta::Work {
            phase: Phase::Admitting,
            completed: 0,
            total: None,
        })
        .expect("open record");
        admit(&self.photo)?;
        emit.push(Delta::Photo {
            width: self.photo.width(),
            height: self.photo.height(),
        })
        .expect("open record");
        if emit.cancel_requested() {
            return Ok(self.empty_result());
        }
        emit.push(Delta::Work {
            phase: Phase::Locating,
            completed: 0,
            total: None,
        })
        .expect("open record");
        let gray = image::DynamicImage::ImageRgb8(self.photo.clone()).into_luma8();
        let found = if self.all {
            crate::locate::find_strips(&gray).map_err(ScanError::Locate)?
        } else {
            vec![crate::locate::find_strip(&gray).map_err(ScanError::Locate)?]
        };
        let total = found.len() as u32;
        emit.push(Delta::Work {
            phase: Phase::Identifying,
            completed: 0,
            total: Some(total),
        })
        .expect("open record");
        for (id, strip) in found.iter().enumerate() {
            emit.push(Delta::Region {
                id: id as u32,
                region: StripRegion {
                    quad: strip.located.frame.fiducials,
                    identity: strip.identity,
                    reading: None,
                },
            })
            .expect("open record");
            emit.push(Delta::Work {
                phase: Phase::Identifying,
                completed: id as u32 + 1,
                total: Some(total),
            })
            .expect("open record");
        }
        emit.push(Delta::Work {
            phase: Phase::Reading,
            completed: 0,
            total: Some(total),
        })
        .expect("open record");
        let mut shares = Vec::with_capacity(found.len());
        for (id, strip) in found.into_iter().enumerate() {
            if emit.cancel_requested() {
                return Ok(self.empty_result());
            }
            let share = crate::strip_scan::read_found(strip, self.scanner.model.as_ref())?;
            emit.push(Delta::Region {
                id: id as u32,
                region: StripRegion {
                    quad: share.quad(),
                    identity: share.identity,
                    reading: Some(Reading {
                        cells: share.cells.clone(),
                        unread: share.unread.clone(),
                    }),
                },
            })
            .expect("open record");
            shares.push(share);
            emit.push(Delta::Work {
                phase: Phase::Reading,
                completed: shares.len() as u32,
                total: Some(total),
            })
            .expect("open record");
        }
        emit.push(Delta::Work {
            phase: Phase::Packing,
            completed: 0,
            total: Some(1),
        })
        .expect("open record");
        let result = ScanResult {
            width: self.photo.width(),
            height: self.photo.height(),
            shares,
            diagnostics: self.options.diagnostics,
        };
        emit.push(Delta::Work {
            phase: Phase::Packing,
            completed: 1,
            total: Some(1),
        })
        .expect("open record");
        Ok(result)
    }

    fn empty_result(&self) -> ScanResult {
        ScanResult {
            width: self.photo.width(),
            height: self.photo.height(),
            shares: Vec::new(),
            diagnostics: self.options.diagnostics,
        }
    }
}

/// Pixels a caller decoded themselves pass the same admission the decoder
/// applies, so supplying RGB cannot reach past the shared limits.
fn admit(image: &RgbImage) -> Result<(), ScanError> {
    bitcoin_vision_core::check_dimensions(image.width(), image.height())
        .map_err(|e| ScanError::Image(e.0))
}

fn decode(encoded: &[u8], options: ScanOptions) -> Result<RgbImage, ScanError> {
    bitcoin_vision_core::decode_image(encoded, options.orientation)
        .map_err(|e| ScanError::Image(e.0))
}

/// Native readings plus the photograph they came from.
#[derive(Clone, Debug)]
pub struct ScanResult {
    /// Canonical image dimensions.
    pub width: u32,
    /// Canonical image dimensions.
    pub height: u32,
    /// Every strip read, in the order they were found.
    pub shares: Vec<ScannedShare>,
    diagnostics: bool,
}

impl ScanResult {
    /// Projects saved decisions only: does not rerun, rectify or reclassify.
    pub fn document(&self) -> Document {
        Document {
            width: self.width,
            height: self.height,
            observations: self
                .shares
                .iter()
                .map(|share| observation(share, self.diagnostics))
                .collect(),
        }
    }
}

/// Everything read from one photograph, as plain data.
#[derive(Clone, Debug, Serialize)]
pub struct Document {
    /// Canonical image dimensions.
    pub width: u32,
    /// Canonical image dimensions.
    pub height: u32,
    /// The strips found, in the order they were found.
    pub observations: Vec<Observation>,
}

/// One strip observed in the photograph: which it is, where it was, and
/// what every cell said.
#[derive(Clone, Debug, Serialize)]
pub struct Observation {
    /// `share`, `seed`, or `unknown` when the printed code could not be read.
    pub kind: &'static str,
    /// The share number, when the paper carried a readable one. A strip from
    /// a worksheet that prints no identity code has none, and the caller
    /// supplies it from what is written at the top.
    pub share: Option<u8>,
    /// Fiducial centres in photo pixels: top-left, top-right, bottom-left,
    /// bottom-right.
    pub quad: [(f64, f64); 4],
    /// Mean over cells of the most probable symbol's probability. Not a
    /// statement that the reading is correct.
    pub confidence: f64,
    /// The reading as written, with `?` where a cell could not be read.
    pub text: Vec<String>,
    /// Twelve words of six cells, in worksheet order.
    pub words: Vec<Vec<Cell>>,
}

/// One cell's reading.
#[derive(Clone, Debug, Serialize)]
pub struct Cell {
    /// Position within the word: 0 and 1 are the word's checksum.
    pub position: usize,
    /// The most probable symbol, or `None` when the cell could not be read.
    pub selected: Option<char>,
    /// That symbol's probability.
    pub probability: f32,
    /// True when the classifier returned nothing usable and the distribution
    /// is uniform; distinguishes "could not read" from "read a `Q`".
    pub unread: bool,
    /// Every symbol with its probability, under `diagnostics`.
    pub candidates: Vec<(char, f32)>,
}

fn observation(share: &ScannedShare, diagnostics: bool) -> Observation {
    let unread = |word: usize, position: usize| share.unread.contains(&(word, position));
    Observation {
        kind: match share.identity {
            Identity::Seed => "seed",
            Identity::Share(_) => "share",
            Identity::Unknown => "unknown",
        },
        share: share.identity.share().map(ShareIndex::number),
        quad: share.quad(),
        confidence: share.confidence(),
        text: share
            .cells
            .iter()
            .enumerate()
            .map(|(word, row)| {
                row.iter()
                    .enumerate()
                    .map(|(position, cell)| {
                        if unread(word, position) {
                            '?'
                        } else {
                            cell.argmax().to_char()
                        }
                    })
                    .collect()
            })
            .collect(),
        words: share
            .cells
            .iter()
            .enumerate()
            .map(|(word, row)| {
                (0..WORD_LEN)
                    .map(|position| {
                        cell(
                            &row[position],
                            position,
                            unread(word, position),
                            diagnostics,
                        )
                    })
                    .collect()
            })
            .collect(),
    }
}

fn cell(distribution: &Distribution, position: usize, unread: bool, diagnostics: bool) -> Cell {
    let best = distribution.argmax();
    Cell {
        position,
        selected: (!unread).then(|| best.to_char()),
        probability: distribution.p(best),
        unread,
        candidates: diagnostics
            .then(|| {
                Symbol::all()
                    .map(|symbol| (symbol.to_char(), distribution.p(symbol)))
                    .collect()
            })
            .unwrap_or_default(),
    }
}
