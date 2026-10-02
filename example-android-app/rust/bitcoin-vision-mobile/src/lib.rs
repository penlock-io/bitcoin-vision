//! The phone bridge over UniFFI: the same pipeline the bench gates,
//! behind a UniFFI surface small enough for an app — photograph
//! strips, keep their soft readings, recover the phrase; and the
//! backup the other way round: photograph a written phrase, read its
//! words for the person to confirm, split them into shares to write
//! down; a new phrase made the way bdk makes a wallet's, the wallet a
//! phrase is, as a descriptor to save and export; and a PSBT reviewed
//! against that descriptor and signed from the review.

#![deny(missing_docs)]

use std::sync::Arc;

use bdk_wallet::KeychainKind;
use bdk_wallet::bitcoin::bip32::Xpriv;
use bdk_wallet::bitcoin::secp256k1::Secp256k1;
use bdk_wallet::bitcoin::{Network, NetworkKind};
use bdk_wallet::keys::bip39::{Language, Mnemonic, WordCount};
use bdk_wallet::keys::{GeneratableKey, GeneratedKey};
use bdk_wallet::miniscript::{Descriptor, DescriptorPublicKey};
use bdk_wallet::template::{Bip86, DescriptorTemplate};
use crate::progress::Observer;
#[cfg(feature = "scan-profile")]
use bitcoin_vision_words::recogniser::Preparation;
use bitcoin_vision_words::scan::Outcome as ScanOutcome;
use bitcoin_vision_words::{ScanError, ScanOptions, ScanResult};
use penlock::soft::search::{Bip39Checksum, Filter, Floor, Outcome, search, slots};
use penlock::soft::{Evidence, SoftDecoded, combine, decode_soft};
use penlock::word::symbols_to_string;
use penlock::{Distribution, ShareCount, Symbol, Word};
use penlock_scan::{Identity, ScannedShare};
use rand::TryRngCore;

mod boxes;
mod diagnostics;
mod photo;
mod progress;
mod psbt;
mod qr;
mod sources;
mod strip_progress;
mod timing;

pub use boxes::{BoxObserver, BoxProgressEvent, BoxProgressUpdate, BoxScan, FinalBox};
pub use diagnostics::{DiagnosedScan, DiagnosticFile};
pub use sources::{DetectionOwner, DetectionPart, DetectionSource, DetectionUnion};

pub use photo::{PhotoUpSource, canonical_photo};
#[cfg(feature = "scan-profile")]
pub use progress::ProgressCallbackProbe;
pub use progress::{
    DeliveryWatch, ProgressDeliveryError, ScanProgressEvent, ScanProgressObserver,
    ScanProgressUpdate, ScanRegion, ScanRegionMapping, ScanRegionState, ScanWorkPhase,
};
pub use strip_progress::{
    StripProgressEvent, StripProgressObserver, StripProgressUpdate, StripWorkPhase,
};

pub use psbt::{FEE_CEILING, OutputLine, Review, review_psbt, sign_review};
pub use qr::{PsbtQrDecoder, PsbtQrEncoder, QrModules, QrScan, psbt_qr_parts, qr_modules};

uniffi::setup_scaffolding!();

/// Everything the surface fails with, in the pipeline's own words.
#[derive(Clone, Debug, uniffi::Error)]
pub enum VisionError {
    /// The bytes did not decode as a photo.
    Photo {
        /// The decoder's words.
        detail: String,
    },
    /// The model bytes failed the classifier contract.
    Model {
        /// The loader's words.
        detail: String,
    },
    /// No strip could be found or read in the photo.
    Scan {
        /// The scanner's words.
        detail: String,
    },
    /// The text does not fit a QR code.
    Qr {
        /// The encoder's words.
        detail: String,
    },
    /// The pair cannot recover a phrase.
    Recover {
        /// Why not.
        detail: String,
    },
    /// The words are not a phrase that can be split.
    Phrase {
        /// Which word, or that the checksum fails.
        detail: String,
    },
    /// The PSBT is refused, or cannot be signed as reviewed.
    Psbt {
        /// The reason, naming the input or output.
        detail: String,
    },
}

impl std::fmt::Display for VisionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VisionError::Photo { detail }
            | VisionError::Model { detail }
            | VisionError::Scan { detail }
            | VisionError::Recover { detail }
            | VisionError::Phrase { detail }
            | VisionError::Psbt { detail }
            | VisionError::Qr { detail } => f.write_str(detail),
        }
    }
}

impl std::error::Error for VisionError {}

/// The recogniser, loaded once per app from the model's bytes.
#[derive(uniffi::Object)]
pub struct Scanner {
    scanner: penlock_scan::Scanner,
}

#[uniffi::export]
impl Scanner {
    /// Builds the recogniser from `cell-reference.onnx`'s bytes.
    #[uniffi::constructor]
    pub fn new(model: Vec<u8>) -> Result<Self, VisionError> {
        Ok(Scanner {
            scanner: penlock_scan::Scanner::new(penlock_scan::ModelBytes { cells: &model })
                .map_err(|e| VisionError::Model {
                    detail: e.to_string(),
                })?,
        })
    }

    /// Reads every strip in one photo (JPEG, PNG or WebP bytes).
    pub fn read(&self, photo: Vec<u8>) -> Result<Vec<Arc<StripReading>>, VisionError> {
        self.read_oriented(photo, 1)
    }

    /// Reads strips after applying the app's resolved EXIF-numbered transform once.
    pub fn read_oriented(
        &self,
        photo: Vec<u8>,
        orientation: u8,
    ) -> Result<Vec<Arc<StripReading>>, VisionError> {
        self.read_oriented_inner(photo, orientation, None)
    }

    /// Reads strips while delivering ordered stage and geometry updates.
    /// The callback receives no photo data, cell probabilities or share text.
    pub fn read_oriented_with_progress(
        &self,
        photo: Vec<u8>,
        orientation: u8,
        observer: Box<dyn StripProgressObserver>,
    ) -> Result<Vec<Arc<StripReading>>, VisionError> {
        self.read_oriented_inner(photo, orientation, Some(observer))
    }

    fn read_oriented_inner(
        &self,
        photo: Vec<u8>,
        orientation: u8,
        observer: Option<Box<dyn StripProgressObserver>>,
    ) -> Result<Vec<Arc<StripReading>>, VisionError> {
        let photo = photo::decode(&photo, orientation).map_err(|error| {
            if let Some(observer) = observer.as_deref() {
                let _ = observer.on_progress(StripProgressEvent {
                    sequence: 1,
                    update: StripProgressUpdate::Failed,
                });
            }
            error
        })?;
        let (scan, state) = self
            .scanner
            .start_all(photo, penlock_scan::ScanOptions::default());
        let outcome = std::thread::scope(|threads| {
            if let Some(observer) = observer.as_deref() {
                let state = state.clone();
                threads.spawn(move || strip_progress::forward(&state, observer));
            }
            scan.run()
        });
        drop(state);
        let read = match outcome {
            penlock_scan::scan::Outcome::Finished(result) => {
                Arc::try_unwrap(result).unwrap_or_else(|shared| (*shared).clone())
            }
            penlock_scan::scan::Outcome::Failed(error) => {
                return Err(VisionError::Scan {
                    detail: error.to_string(),
                });
            }
            penlock_scan::scan::Outcome::Cancelled | penlock_scan::scan::Outcome::Abandoned => {
                return Err(VisionError::Scan {
                    detail: "the scan stopped before it finished".into(),
                });
            }
        };
        Ok(read
            .shares
            .into_iter()
            .map(|share| {
                Arc::new(StripReading {
                    original: share.clone(),
                    edits: vec![None; share.cells.len() * penlock::word::WORD_LEN],
                    share,
                })
            })
            .collect())
    }
}

/// One strip read from a photo, its soft readings kept for recovery.
#[derive(uniffi::Object)]
pub struct StripReading {
    share: ScannedShare,
    original: ScannedShare,
    edits: Vec<Option<Symbol>>,
}

/// Finished strip evidence for review. Cell readings never enter progress events.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct StripReview {
    /// Printed strip marking, or unknown when it could not be read.
    pub identity: StripIdentity,
    /// Located strip polygon, top-left, top-right, bottom-right, bottom-left.
    pub corners: Vec<f32>,
    /// Rows in worksheet order.
    pub rows: Vec<StripRowReview>,
}

/// One six-symbol row of a photographed strip.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct StripRowReview {
    /// One-based row number.
    pub number: u32,
    /// Six cells; positions zero and one are shares of checksum symbols.
    pub cells: Vec<StripCellReview>,
}

/// Original classifier evidence and an optional explicit human correction.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct StripCellReview {
    /// Zero-based position within the row.
    pub position: u32,
    /// Original model symbol, absent when unreadable.
    pub selected: Option<String>,
    /// Model support for that symbol, absent when unreadable.
    pub probability: Option<f32>,
    /// Whether the model produced no usable reading.
    pub unread: bool,
    /// Human replacement; never overwrites the evidence above.
    pub replacement: Option<String>,
    /// Production grown-cell window in canonical photo coordinates, clockwise.
    pub corners: Vec<f32>,
}

/// What local word-code decoding can establish after both share readings
/// are combined. A single strip has no standalone checksum.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CombinedRowStatus {
    /// A unique word code matches the combined symbols without inference.
    Exact,
    /// One symbol was corrected to a unique nearby word code.
    Corrected,
    /// Ambiguous or weak evidence; review both photographed rows.
    NeedsReview,
}

/// One row's pair-level check before recovering or using the phrase.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CombinedRowReview {
    /// One-based row number.
    pub number: u32,
    /// Result of decoding the combined symbols against the word code.
    pub status: CombinedRowStatus,
    /// Zero-based position when exactly one symbol differs.
    pub position: Option<u32>,
    /// The combined top symbol at that position, if any.
    pub observed: Option<String>,
    /// The recovered word's symbol at that position, if any.
    pub expected: Option<String>,
}

/// Combined evidence available after both individual strips were reviewed.
/// This does not run phrase recovery or expose a seed phrase.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct CombinedStripReview {
    /// Twelve rows in phrase order; no raw seed is sent through progress.
    pub rows: Vec<CombinedRowReview>,
}

/// What the strip's printed marking said it was.
#[derive(Clone, Copy, PartialEq, Eq, Debug, uniffi::Enum)]
pub enum StripIdentity {
    /// The seed-phrase strip.
    Seed,
    /// A share strip.
    Share {
        /// The share number written on the worksheet, in `1..=3`.
        index: u8,
    },
    /// The marking could not be read.
    Unknown,
}

#[uniffi::export]
impl StripReading {
    /// What the strip is.
    pub fn identity(&self) -> StripIdentity {
        match self.share.identity {
            Identity::Seed => StripIdentity::Seed,
            Identity::Share(i) => StripIdentity::Share { index: i.number() },
            Identity::Unknown => StripIdentity::Unknown,
        }
    }

    /// Rows the strip carries.
    pub fn rows(&self) -> u32 {
        self.share.cells.len() as u32
    }

    /// Cells the recogniser could not read at all.
    pub fn unread(&self) -> u32 {
        self.original.unread.len() as u32
    }

    /// Immutable classifier evidence, explicit edits and native crop windows.
    pub fn review(&self) -> StripReview {
        let fiducials = self.original.quad();
        let corners = [0usize, 1, 3, 2]
            .into_iter()
            .flat_map(|i| {
                let (x, y) = fiducials[i];
                [x as f32, y as f32]
            })
            .collect();
        let rows = self
            .original
            .cells
            .iter()
            .enumerate()
            .map(|(row, cells)| StripRowReview {
                number: row as u32 + 1,
                cells: cells
                    .iter()
                    .enumerate()
                    .map(|(position, distribution)| {
                        let unread = self.original.unread.contains(&(row, position));
                        let best = distribution.argmax();
                        let corners = self.original.cell_quad(row, position)
                        .into_iter()
                        .flat_map(|(x, y)| [x as f32, y as f32])
                        .collect();
                        StripCellReview {
                            position: position as u32,
                            selected: (!unread).then(|| best.to_char().to_string()),
                            probability: (!unread).then(|| distribution.p(best)),
                            unread,
                            replacement: self.edits[row * penlock::word::WORD_LEN + position]
                                .map(|symbol| symbol.to_char().to_string()),
                            corners,
                        }
                    })
                    .collect(),
            })
            .collect();
        StripReview {
            identity: self.identity(),
            corners,
            rows,
        }
    }

    /// Override one cell for recovery while retaining its original model read.
    pub fn with_cell(
        &self,
        row: u32,
        position: u32,
        text: String,
    ) -> Result<Arc<Self>, VisionError> {
        let chars: Vec<_> = text.chars().collect();
        let symbol = match chars.as_slice() {
            [c] => Symbol::from_char(*c),
            _ => None,
        }
        .ok_or_else(|| VisionError::Recover {
            detail: "Choose one worksheet symbol: =, #, A–Z or -.".into(),
        })?;
        let row = row as usize;
        let position = position as usize;
        if row >= self.share.cells.len() || position >= penlock::word::WORD_LEN {
            return Err(VisionError::Recover {
                detail: "That cell is outside the photographed strip.".into(),
            });
        }
        let mut edited = Self {
            share: self.share.clone(),
            original: self.original.clone(),
            edits: self.edits.clone(),
        };
        edited.share.cells[row][position] = Distribution::one_hot(symbol);
        edited.share.unread.retain(|&at| at != (row, position));
        edited.edits[row * penlock::word::WORD_LEN + position] = Some(symbol);
        Ok(Arc::new(edited))
    }

    /// Undo one correction, including the model's original unread state.
    pub fn without_cell_edit(&self, row: u32, position: u32) -> Result<Arc<Self>, VisionError> {
        let row = row as usize;
        let position = position as usize;
        if row >= self.share.cells.len() || position >= penlock::word::WORD_LEN {
            return Err(VisionError::Recover {
                detail: "That cell is outside the photographed strip.".into(),
            });
        }
        let mut edited = Self {
            share: self.share.clone(),
            original: self.original.clone(),
            edits: self.edits.clone(),
        };
        edited.share.cells[row][position] = self.original.cells[row][position];
        edited.share.unread.retain(|&at| at != (row, position));
        if self.original.unread.contains(&(row, position)) {
            edited.share.unread.push((row, position));
        }
        edited.edits[row * penlock::word::WORD_LEN + position] = None;
        Ok(Arc::new(edited))
    }
}

/// Recovers the phrase from two share strips: their readings combined,
/// candidate phrases enumerated best-first, the first that passes the
/// BIP39 checksum returned. The checksum is a filter — a wrong phrase
/// slips through about one time in sixteen — not an oracle; a saved
/// wallet descriptor will later confirm the phrase properly.
#[uniffi::export]
pub fn recover(a: Arc<StripReading>, b: Arc<StripReading>) -> Result<Vec<String>, VisionError> {
    let combined = combined_strip_rows(&a, &b)?;
    let ranked = slots(&combined, &[], Floor::DEFAULT);
    match search(&ranked, &[&Bip39Checksum], None, 0) {
        Outcome::Unconfirmed { words, .. } => Ok(words.iter().map(|w| w.to_string()).collect()),
        _ => Err(VisionError::Recover {
            detail: "no candidate phrase passed the BIP39 checksum".into(),
        }),
    }
}

fn combined_strip_rows(
    a: &StripReading,
    b: &StripReading,
) -> Result<Vec<[Distribution; penlock::word::WORD_LEN]>, VisionError> {
    let index = |s: &StripReading| {
        s.share
            .identity
            .share()
            .ok_or_else(|| VisionError::Recover {
                detail: "recovery needs two share strips".into(),
            })
    };
    let (index_a, index_b) = (index(a)?, index(b)?);
    if a.share.cells.len() != b.share.cells.len() || a.share.cells.len() != 12 {
        return Err(VisionError::Recover {
            detail: "both shares must contain twelve rows".into(),
        });
    }
    let mut combined = Vec::with_capacity(a.share.cells.len());
    for (x, y) in a.share.cells.iter().zip(&b.share.cells) {
        combined.push(
            combine(x, index_a, y, index_b).map_err(|e| VisionError::Recover {
                detail: e.to_string(),
            })?,
        );
    }
    Ok(combined)
}

/// Decode each combined row locally, without running whole-phrase recovery.
/// A single strip cannot validate these checksums; this is pair-only.
#[uniffi::export]
pub fn review_combined_strips(
    a: Arc<StripReading>,
    b: Arc<StripReading>,
) -> Result<CombinedStripReview, VisionError> {
    let combined = combined_strip_rows(&a, &b)?;
    let rows = combined
        .iter()
        .enumerate()
        .map(|(row, readings)| {
            let (status, one) = match decode_soft(readings) {
                SoftDecoded::Exact { .. } => (CombinedRowStatus::Exact, None),
                SoftDecoded::Resolved { evidence, .. } => match evidence.as_slice() {
                    [
                        Evidence::Substituted {
                            position, from, to, ..
                        },
                    ] => (CombinedRowStatus::Corrected, Some((*position, *from, *to))),
                    _ => (CombinedRowStatus::NeedsReview, None),
                },
                SoftDecoded::Candidates(_) | SoftDecoded::Unrecognized => {
                    (CombinedRowStatus::NeedsReview, None)
                }
            };
            CombinedRowReview {
                number: row as u32 + 1,
                status,
                position: one.map(|(position, _, _)| position as u32),
                observed: one.map(|(_, symbol, _)| symbol.to_char().to_string()),
                expected: one.map(|(_, _, symbol)| symbol.to_char().to_string()),
            }
        })
        .collect();
    Ok(CombinedStripReview { rows })
}

#[cfg(test)]
mod strip_review_tests {
    use super::*;
    use penlock::ShareIndex;
    use penlock_scan::locate::{Identity, find_strip};
    use penlock_scan::sheet::{cut_strip, front_png};

    fn pair() -> (Arc<StripReading>, Arc<StripReading>) {
        let sheet = front_png(None, 110.0).unwrap();
        let strip =
            image::DynamicImage::ImageRgb8(cut_strip(&sheet, 110.0, 1)).to_luma8();
        let found = find_strip(&strip).unwrap();
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let words = Word::parse_phrase(phrase).unwrap();
        let make = |index: ShareIndex| {
            let cells = words
                .iter()
                .map(|word| {
                    let code = word.symbols();
                    std::array::from_fn(|position| {
                        let slope = Symbol::from_residue((position + 3) as u32);
                        Distribution::one_hot(slope + code[position] * index.symbol())
                    })
                })
                .collect();
            let share = ScannedShare {
                identity: Identity::Share(index),
                cells,
                unread: Vec::new(),
                located: found.located.clone(),
            };
            Arc::new(StripReading {
                original: share.clone(),
                share,
                edits: vec![None; 12 * penlock::word::WORD_LEN],
            })
        };
        (make(ShareIndex::ONE), make(ShareIndex::TWO))
    }

    #[test]
    fn finished_review_projects_real_crop_windows_and_retains_original_after_edit() {
        let (a, b) = pair();
        let review = a.review();
        assert_eq!(review.identity, StripIdentity::Share { index: 1 });
        assert_eq!(review.rows.len(), 12);
        assert_eq!(review.rows[0].cells.len(), 6);
        assert_eq!(review.corners.len(), 8);
        assert!(
            review
                .rows
                .iter()
                .flat_map(|r| &r.cells)
                .all(|c| c.corners.len() == 8 && c.corners.iter().all(|x| x.is_finite()))
        );
        assert_eq!(recover(a.clone(), b.clone()).unwrap()[11], "about");
        assert!(
            review_combined_strips(a.clone(), b.clone())
                .unwrap()
                .rows
                .iter()
                .all(|r| r.status == CombinedRowStatus::Exact)
        );

        let before = combined_strip_rows(&a, &a).unwrap_err();
        assert!(before.to_string().contains("share"));
        let original = &review.rows[0].cells[0];
        let replacement = if original.selected.as_deref() == Some("A") {
            "B"
        } else {
            "A"
        };
        let edited = a.with_cell(0, 0, replacement.into()).unwrap();
        let changed = &edited.review().rows[0].cells[0];
        assert_eq!(changed.selected, original.selected);
        assert_eq!(changed.probability, original.probability);
        assert_eq!(changed.replacement.as_deref(), Some(replacement));
        assert_eq!(
            edited.share.cells[0][0].argmax().to_char().to_string(),
            replacement
        );
        let combined_before = combined_strip_rows(&a, &b).unwrap();
        let combined_after = combined_strip_rows(&edited, &b).unwrap();
        assert_ne!(
            combined_before[0][0].argmax(),
            combined_after[0][0].argmax()
        );
        assert_eq!(
            edited.without_cell_edit(0, 0).unwrap().share.cells[0][0],
            a.share.cells[0][0]
        );
    }

    #[test]
    fn pair_check_reports_a_corrected_symbol_only_after_both_shares_are_combined() {
        let (a, b) = pair();
        let bad = if a.share.cells[0][2].argmax() == Symbol::ZERO {
            "#"
        } else {
            "="
        };
        let edited = a.with_cell(0, 2, bad.into()).unwrap();
        let rows = review_combined_strips(edited, b).unwrap().rows;
        assert_eq!(rows[0].status, CombinedRowStatus::Corrected);
        assert_eq!(rows[0].position, Some(2));
        assert!(
            rows[1..]
                .iter()
                .all(|row| row.status == CombinedRowStatus::Exact)
        );
    }

    #[test]
    fn unread_cell_stays_visible_as_original_evidence_after_a_override() {
        let (a, _) = pair();
        let mut missing = (*a).share.clone();
        missing.cells[3][4] = Distribution::uniform();
        missing.unread.push((3, 4));
        let a = StripReading {
            original: missing.clone(),
            share: missing,
            edits: vec![None; 12 * penlock::word::WORD_LEN],
        };
        assert!(a.review().rows[3].cells[4].unread);
        assert_eq!(a.review().rows[3].cells[4].selected, None);
        let edited = a.with_cell(3, 4, "A".into()).unwrap();
        assert!(edited.review().rows[3].cells[4].unread);
        assert_eq!(
            edited.review().rows[3].cells[4].replacement.as_deref(),
            Some("A")
        );
        assert!(!edited.share.unread.contains(&(3, 4)));
        let restored = edited.without_cell_edit(3, 4).unwrap();
        assert!(restored.share.unread.contains(&(3, 4)));
        assert_eq!(restored.share.cells[3][4], Distribution::uniform());
    }
}

/// The phrase reader: the word detector, the word model with its
/// calibration, and the text recogniser that says what is written
/// whether or not it is a word, loaded once per app from the bundled
/// bytes.
#[derive(uniffi::Object)]
pub struct PhraseScanner {
    scanner: bitcoin_vision_words::Scanner,
}

/// One list word with the probability the model gives it.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct RankedWord {
    /// The list word.
    pub word: String,
    /// Its probability under the model.
    pub probability: f32,
}

/// Original observation retained by an extent replacement, not a native join.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct ExtentParent {
    /// Index into the returned page's words, including inactive alternatives.
    pub word_index: u32,
    /// Whether this original was left out before the expansion was selected.
    pub stray: bool,
}

/// One word found on the page and read.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct OcrObservation {
    /// Original photo polygon.
    pub corners: Vec<f32>,
    /// Exact crop supplied to OCR.
    pub crop_png: Vec<u8>,
    /// Verbatim OCR of that crop.
    pub raw: String,
}

/// Matching input is distinct from verbatim OCR.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct MatchingEvidence {
    /// Selected matching text before normalisation.
    pub text: String,
    /// Whether the selected literal belongs to original_ocr.
    pub original: bool,
    /// Leading UTF-8 bytes omitted from that literal.
    pub removed_prefix_bytes: u32,
}

/// Observed label values are not trusted word numbers.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct LabelObservation {
    /// Source polygon in photo coordinates (parent polygon for a prefix token).
    pub corners: Vec<f32>,
    /// Literal label observation.
    pub literal: String,
    /// prefix, token, standalone or beside.
    pub origin: String,
    /// Exact observed digits; not a trusted phrase position.
    pub ordinal: Option<u32>,
    /// Mandatory dotted-label evidence.
    pub dotted: bool,
    /// No unique geometric owner was found.
    pub ambiguous: bool,
}

/// One word found on the page and read.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct WordReading {
    /// The word's four corners in photo pixels, clockwise from the top
    /// left, as x1, y1, ... x4, y4.
    pub corners: Vec<f32>,
    /// The model's five most probable list words, most probable first.
    pub ranked: Vec<RankedWord>,
    /// Whether the calibration accepts the top word; otherwise the
    /// person should look at the crop.
    pub accepted: bool,
    /// The word to show first: the hybrid pick over the recogniser's
    /// read and the model's five, or the model's top without a read.
    pub read: String,
    /// The recogniser's raw read of the crop, empty without one.
    pub raw: String,
    /// Original crop/read retained only when an ink cut was adopted.
    pub original_ocr: Option<OcrObservation>,
    /// Explicit source/transform used for word selection.
    pub matching: Option<MatchingEvidence>,
    /// Every label observation, including unknown ordinals.
    pub labels: Vec<LabelObservation>,
    /// Conflicting or duplicate exact label values.
    pub label_conflict: bool,
    /// Not a word: left out of both reading orders.
    pub stray: bool,
    /// The item number the page's numbering gives the word, when the
    /// page is numbered and this word has a place in the run.
    pub number: Option<u32>,
    /// A word by its read, but far from the phrase's region: a stray
    /// for that reason, not for what it read as.
    pub apart: bool,
    /// The level crop the model read, as PNG bytes, for the person to
    /// compare the reading against.
    pub crop_png: Vec<u8>,
    /// Original pieces replaced by this joined word, indexed into the page.
    /// Restoring those pieces must deactivate this word, and vice versa.
    pub joined_from: Vec<u32>,
    /// One or two original observations replaced by this expanded crop.
    /// Switching back restores their prior keep state and clears user checks.
    pub expanded_from: Vec<ExtentParent>,
}

impl TryFrom<&bitcoin_vision_words::review::ReviewWord> for WordReading {
    type Error = VisionError;

    fn try_from(w: &bitcoin_vision_words::review::ReviewWord) -> Result<Self, Self::Error> {
        let chosen = w.selected.ok_or_else(|| VisionError::Scan {
                detail: "word observation has no selection".into(),
            })?;
        Ok(Self {
            corners: w.quad.iter().flat_map(|&(x, y)| [x, y]).collect(),
            ranked: w
                .ranked
                .iter()
                .map(|&(word, probability)| RankedWord {
                    word: word.to_owned(),
                    probability,
                })
                .collect(),
            accepted: w.accepted,
            read: chosen.to_owned(),
            raw: w.raw.clone().unwrap_or_default(),
            original_ocr: w
                .original
                .as_ref()
                .map(|r| OcrObservation {
                    corners: r.quad.iter().flat_map(|&(x, y)| [x, y]).collect(),
                    crop_png: r.crop_png.clone(),
                    raw: r.raw.clone(),
                })
                ,
            matching: w.matching.as_ref().map(|m| MatchingEvidence {
                text: m.text.clone(),
                original: m.original,
                removed_prefix_bytes: m.removed_prefix_bytes,
            }),
            labels: w
                .labels
                .iter()
                .map(|l| LabelObservation {
                    corners: l.quad.iter().flat_map(|&(x, y)| [x, y]).collect(),
                    literal: l.literal.clone(),
                    origin: l.origin.clone(),
                    ordinal: l.ordinal,
                    dotted: l.dotted,
                    ambiguous: l.ambiguous,
                })
                .collect(),
            label_conflict: w.label_conflict,
            stray: w.stray,
            number: w.number,
            apart: w.apart,
            crop_png: w.crop_png.clone(),
            joined_from: w.joined_from.clone(),
            expanded_from: w
                .expanded_from
                .iter()
                .map(|p| ExtentParent {
                    word_index: p.word_index,
                    stray: p.stray,
                })
                .collect(),
        })
    }
}

/// What the item numbers written beside the words made, over the
/// whole page.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Numbering {
    /// Too few numbers to trust a sequence; list_numbered is independent.
    None,
    /// The numbers read as a run 1…count: `missing` are the numbers no
    /// word carries, each a word not found; `out_of_place` are numbers
    /// whose place on the page is not their place in the run.
    Held {
        /// The highest number the run reaches.
        count: u32,
        /// The numbers no word carries.
        missing: Vec<u32>,
        /// The numbers out of their place on the page.
        out_of_place: Vec<u32>,
        /// Indices into `words` that carry a label the run gave no
        /// number to.
        unresolved: Vec<u32>,
    },
    /// The numbers contradict one another, so none is trusted.
    Inconsistent {
        /// What contradicted what.
        detail: String,
    },
}

/// How a photo was read.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Layout {
    /// A recovery phrase sheet, found by its marks and read field by
    /// field: the twelve fields in order, both orders the same, a
    /// blank field a stray at its place.
    WordSheet,
    /// Any other page: words found by the detector, in either order.
    Page,
}

/// The shared Rust stage's initial traversal, mapped without re-deciding it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum InitialOrder {
    /// Held numbers take precedence.
    Numbers,
    /// The stage chose rows.
    Rows,
    /// The stage chose columns.
    Columns,
}

impl InitialOrder {
    fn from_name(value: &str) -> Self {
        match value {
            "numbers" => Self::Numbers,
            "rows" => Self::Rows,
            "columns" => Self::Columns,
            _ => unreachable!("the scanner has three traversal names"),
        }
    }
}

/// A photographed page read: every word, the two orders the words can
/// be read in, and whether either passes the BIP39 checksum. Passing
/// means the phrase is well formed, never that it is right: a wrong
/// twelve-word phrase passes about one time in sixteen.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct PhraseScan {
    /// Positive numbered-list mode, even without a trusted numeric order.
    pub list_numbered: bool,
    /// How the photo was read.
    pub layout: Layout,
    /// The photo's width in pixels.
    pub width: u32,
    /// The photo's height in pixels.
    pub height: u32,
    /// The words found.
    pub words: Vec<WordReading>,
    /// Indices into `words` reading down columns, left to right, strays
    /// included at their places.
    pub columns: Vec<u32>,
    /// Indices into `words` reading along rows, top to bottom.
    pub rows: Vec<u32>,
    /// Whether the kept words' picks in column order pass the checksum.
    pub columns_pass: bool,
    /// Whether the kept words' picks in row order pass the checksum.
    pub rows_pass: bool,
    /// What the page's item numbers made.
    pub numbering: Numbering,
    /// Indices into `words` in the numbers' order: the numbered words
    /// by number, then the rest in column order; the column order on a
    /// page without numbers.
    pub numbered: Vec<u32>,
    /// Whether the kept words' picks in the numbers' order pass the
    /// checksum.
    pub numbered_pass: bool,
    /// The stage's initial choice; consumers must not reimplement its policy.
    pub initial_order: InitialOrder,
    /// Initial traversal lacks independent layout/number support; review positions.
    pub order_requires_review: bool,
    /// Why the shared native traversal was suggested.
    pub order_basis: String,
    /// Raw detector geometry and outcomes, including ink with no word reading.
    pub sources: Vec<DetectionSource>,
}

impl PhraseScanner {
    /// Read one synthetic exact-width crop for resident-cache diagnostics.
    /// Deliberately outside the UniFFI-exported implementation.
    #[cfg(feature = "scan-profile")]
    pub fn profile_blank_ocr(&self, width: u32) -> Result<(), VisionError> {
        self.scanner
            .profile_blank_ocr(width)
            .map_err(|error| VisionError::Model {
                detail: error.to_string(),
            })
    }

    fn build(
        detector: Vec<u8>,
        model: Vec<u8>,
        calibration: String,
        recogniser: Vec<u8>,
        dictionary: String,
    ) -> Result<Self, VisionError> {
        Ok(PhraseScanner {
            scanner: bitcoin_vision_words::Scanner::new(bitcoin_vision_words::ModelBytes {
                detector: &detector,
                classifier: &model,
                calibration: &calibration,
                recogniser: &recogniser,
                dictionary: &dictionary,
            })
            .map_err(|error| VisionError::Model {
                detail: error.to_string(),
            })?,
        })
    }

    /// Diagnostic constructor only, deliberately not exported to UniFFI. The
    /// app's normal constructor has only the symbolic preparation path.
    #[cfg(feature = "scan-profile")]
    pub fn new_for_profile(
        detector: Vec<u8>,
        model: Vec<u8>,
        calibration: String,
        recogniser: Vec<u8>,
        dictionary: String,
        preparation: Preparation,
    ) -> Result<Self, VisionError> {
        Ok(Self {
            scanner: bitcoin_vision_words::Scanner::new_with_preparation(
                bitcoin_vision_words::ModelBytes {
                    detector: &detector,
                    classifier: &model,
                    calibration: &calibration,
                    recogniser: &recogniser,
                    dictionary: &dictionary,
                },
                preparation,
            )
            .map_err(|error| VisionError::Model {
                detail: error.to_string(),
            })?,
        })
    }
}

#[uniffi::export]
impl PhraseScanner {
    /// Builds the reader from the bytes of `word-detector.onnx`,
    /// `word-reference.onnx` with the text of `word-reference.calibration`
    /// (refusing a model the calibration was not selected on), and
    /// `text-recogniser.onnx` with the text of its dictionary.
    #[uniffi::constructor]
    pub fn new(
        detector: Vec<u8>,
        model: Vec<u8>,
        calibration: String,
        recogniser: Vec<u8>,
        dictionary: String,
    ) -> Result<Self, VisionError> {
        let _init = timing::span("mobile.init");
        Self::build(
            detector,
            model,
            calibration,
            recogniser,
            dictionary,
        )
    }

    /// Reads every word in one photo of a written phrase (JPEG, PNG or
    /// WebP bytes).
    pub fn scan(&self, photo: Vec<u8>) -> Result<PhraseScan, VisionError> {
        self.scan_oriented(photo, 1)
    }

    /// Reads in the app's canonical frame. All returned coordinates and crops
    /// refer to the decoded image after this EXIF-numbered transform, not raw bytes.
    pub fn scan_oriented(
        &self,
        photo: Vec<u8>,
        orientation: u8,
    ) -> Result<PhraseScan, VisionError> {
        self.scan_with_photo_up(photo, orientation, PhotoUpSource::Unknown)
    }

    /// Canonical-frame scan with independent caller provenance. Orientation
    /// applies once to pixels; photo-up is only a page writing-direction hint.
    pub fn scan_with_photo_up(
        &self,
        photo: Vec<u8>,
        orientation: u8,
        photo_up: PhotoUpSource,
    ) -> Result<PhraseScan, VisionError> {
        self.scan_with_observer(photo, orientation, photo_up, None)
    }

    /// The same scan/result with live, per-call geometry and phase callbacks.
    /// Callback failure or detachment does not cancel native recognition.
    pub fn scan_oriented_with_progress(
        &self,
        photo: Vec<u8>,
        orientation: u8,
        observer: Box<dyn ScanProgressObserver>,
    ) -> Result<PhraseScan, VisionError> {
        self.scan_with_photo_up_and_progress(photo, orientation, PhotoUpSource::Unknown, observer)
    }

    /// The same provenance-aware scan with per-call progress.
    pub fn scan_with_photo_up_and_progress(
        &self,
        photo: Vec<u8>,
        orientation: u8,
        photo_up: PhotoUpSource,
        observer: Box<dyn ScanProgressObserver>,
    ) -> Result<PhraseScan, VisionError> {
        let observer = progress::CallbackObserver::new(observer);
        self.scan_with_observer(photo, orientation, photo_up, Some(&observer))
    }

    /// Explicit per-call decision recording for a future saved bug export.
    /// Shares the loaded immutable classifier plan; does not change the resident
    /// reader, rerun recognition, write files, or enable tracing on later scans.
    pub fn scan_oriented_with_diagnostics(
        &self,
        photo: Vec<u8>,
        orientation: u8,
        observer: Box<dyn ScanProgressObserver>,
    ) -> Result<DiagnosedScan, VisionError> {
        self.scan_with_photo_up_and_diagnostics(
            photo,
            orientation,
            PhotoUpSource::Unknown,
            observer,
        )
    }

    /// Explicit decision recording, with provenance and the actual pixel
    /// transform recorded separately. The resident reader is never mutated.
    pub fn scan_with_photo_up_and_diagnostics(
        &self,
        photo: Vec<u8>,
        orientation: u8,
        photo_up: PhotoUpSource,
        observer: Box<dyn ScanProgressObserver>,
    ) -> Result<DiagnosedScan, VisionError> {
        let observer = progress::CallbackObserver::new(observer);
        let options = ScanOptions {
            diagnostics: true,
            photo_up: photo_up.into(),
            ..ScanOptions::default()
        };
        let mut files = Vec::new();
        let scan = progress::complete(Some(&observer), || {
            let read = self.scan_page(photo, orientation, options, Some(&observer))?;
            let result = pack_scan(&read)?;
            files = diagnostics::pack(&read, orientation, photo_up)?;
            Ok((result, read.regions))
        })?;
        Ok(DiagnosedScan { scan, files })
    }

    /// Return final selected boxes from an image, without exposing words.
    /// Uses the same pipeline (including internal recognition) and canonical
    /// EXIF-numbered orientation as scan_oriented. No second scan is performed.
    pub fn scan_boxes(&self, photo: Vec<u8>, orientation: u8) -> Result<BoxScan, VisionError> {
        self.scan_boxes_observed(photo, orientation, None)
    }

    /// Boxes-only scan with live provisional geometry and an authoritative
    /// final set. Callback detachment does not cancel native computation.
    pub fn scan_boxes_with_progress(
        &self,
        photo: Vec<u8>,
        orientation: u8,
        observer: Box<dyn BoxObserver>,
    ) -> Result<BoxScan, VisionError> {
        self.scan_boxes_observed(photo, orientation, Some(observer))
    }
}

impl PhraseScanner {
    fn scan_boxes_observed(
        &self,
        photo: Vec<u8>,
        orientation: u8,
        callback: Option<Box<dyn BoxObserver>>,
    ) -> Result<BoxScan, VisionError> {
        let _total = timing::span("mobile.total");
        let observer = boxes::Callback::new(callback);
        observer.complete(|| {
            // Some(observer) keeps the stage-owned ID mapping even without a
            // foreign callback. It neither selects boxes nor retains readings.
            let read =
                self.scan_page(photo, orientation, ScanOptions::default(), Some(&observer))?;
            read.selected_boxes().map_err(|error| VisionError::Scan {
                detail: error.to_string(),
            })
        })
    }

    /// Historical baseline/E3 cost comparison through the shared scan owner.
    /// Deliberately outside UniFFI; normal app calls always use lean E3.
    #[cfg(feature = "extent-experiment")]
    pub fn scan_extent_for_profile(
        &self,
        photo: Vec<u8>,
        use_extent: bool,
    ) -> Result<(PhraseScan, String), VisionError> {
        let _total = timing::span("mobile.total");
        let read = self.scan_extent(
            photo,
            use_extent,
            bitcoin_vision_words::extent::Audit::Components,
        )?;
        let report = read
            .extent
            .as_ref()
            .map(|r| {
                let value = r.to_json();
                let _serialize = timing::span("phrase.extent.serialize");
                value.to_string()
            })
            .unwrap_or_default();
        Ok((pack_scan(&read)?, report))
    }

    /// Same lean E3 arm as normal scans, retaining its compact report for the
    /// benchmark only. False explicitly selects the historical baseline.
    #[cfg(feature = "extent-experiment")]
    pub fn scan_extent_lean_for_profile(
        &self,
        photo: Vec<u8>,
        use_extent: bool,
    ) -> Result<(PhraseScan, Option<bitcoin_vision_words::extent::Report>), VisionError> {
        let _total = timing::span("mobile.total");
        let read =
            self.scan_extent(photo, use_extent, bitcoin_vision_words::extent::Audit::None)?;
        let scan = pack_scan(&read)?;
        let report = read
            .extent
            .map(|r| std::sync::Arc::try_unwrap(r).expect("the result is the report's only owner"));
        Ok((scan, report))
    }

    fn scan_with_observer(
        &self,
        photo: Vec<u8>,
        orientation: u8,
        photo_up: PhotoUpSource,
        observer: Option<&dyn Observer>,
    ) -> Result<PhraseScan, VisionError> {
        let _total = timing::span("mobile.total");
        let options = ScanOptions {
            photo_up: photo_up.into(),
            ..ScanOptions::default()
        };
        progress::complete(observer, || {
            let read = self.scan_page(photo, orientation, options, observer)?;
            Ok((pack_scan(&read)?, read.regions))
        })
    }

    /// Reads a phrase: decodes the photo in the app's frame, then drives the
    /// word pipeline's scan to its end, forwarding its record to `observer`
    /// as it grows. Everything between is the scan's, including whether the
    /// photo is a sheet.
    fn scan_page(
        &self,
        photo: Vec<u8>,
        orientation: u8,
        options: ScanOptions,
        observer: Option<&dyn Observer>,
    ) -> Result<ScanResult, VisionError> {
        progress::native::work(
            observer,
            progress::native::Phase::Preparing,
            0,
            None,
        );
        let photo = photo::decode(&photo, orientation)?;
        let (scan, state) = self.scanner.start(photo, options);
        let outcome = std::thread::scope(|threads| {
            if let Some(observer) = observer {
                let state = state.clone();
                threads.spawn(move || progress::forward(&state, observer));
            }
            scan.run()
        });
        // The record holds the result too; dropping the last view of it
        // leaves the result with one owner, so it is moved rather than copied.
        drop(state);
        match outcome {
            ScanOutcome::Finished(result) => {
                Ok(Arc::try_unwrap(result).unwrap_or_else(|shared| (*shared).clone()))
            }
            ScanOutcome::Failed(ScanError::Image(detail)) => Err(VisionError::Photo { detail }),
            ScanOutcome::Failed(ScanError::Model(detail)) => Err(VisionError::Model { detail }),
            ScanOutcome::Failed(ScanError::Processing(detail)) => Err(VisionError::Scan { detail }),
            ScanOutcome::Cancelled | ScanOutcome::Abandoned => Err(VisionError::Scan {
                detail: "the scan stopped before it finished".into(),
            }),
        }
    }

    #[cfg(feature = "extent-experiment")]
    fn scan_extent(
        &self,
        photo: Vec<u8>,
        use_extent: bool,
        audit: bitcoin_vision_words::extent::Audit,
    ) -> Result<ScanResult, VisionError> {
        let options = ScanOptions {
            extent: if use_extent {
                bitcoin_vision_words::Extent::E3(audit)
            } else {
                bitcoin_vision_words::Extent::Baseline
            },
            ..ScanOptions::default()
        };
        self.scan_page(photo, 1, options, None)
    }
}

fn pack_scan(scan: &ScanResult) -> Result<PhraseScan, VisionError> {
    let review = scan.review().map_err(|error| VisionError::Scan {
        detail: error.to_string(),
    })?;
    let layout = match review.found {
        bitcoin_vision_words::Found::Page => Layout::Page,
        bitcoin_vision_words::Found::Sheet => Layout::WordSheet,
    };
    let _pack = timing::span("mobile.pack_result");
    let mut words = Vec::with_capacity(review.words.len());
    for w in &review.words {
        words.push(WordReading::try_from(w)?);
    }
    let numbering = match &review.numbering {
        bitcoin_vision_words::review::ReviewNumbering::None => Numbering::None,
        bitcoin_vision_words::review::ReviewNumbering::Held {
            count,
            missing,
            out_of_place,
            unresolved,
        } => Numbering::Held {
            count: *count,
            missing: missing.clone(),
            out_of_place: out_of_place.clone(),
            unresolved: unresolved.clone(),
        },
        bitcoin_vision_words::review::ReviewNumbering::Inconsistent { detail } => {
            Numbering::Inconsistent {
                detail: detail.clone(),
            }
        }
    };
    Ok(PhraseScan {
        list_numbered: review.list_numbered,
        layout,
        width: review.width,
        height: review.height,
        columns_pass: review.columns_pass,
        rows_pass: review.rows_pass,
        numbered_pass: review.numbered_pass,
        initial_order: InitialOrder::from_name(review.initial_order),
        order_requires_review: review.order_requires_review,
        order_basis: review.order_basis.to_owned(),
        columns: review.columns,
        rows: review.rows,
        numbered: review.numbered,
        numbering,
        words,
        sources: sources::pack(&review.sources),
    })
}

/// Numeric diagnostics for the isolated app timing build. Drain on the same
/// calling thread after the synchronous constructor/scan, outside their spans.
/// No photo, recognized text or ranked word is included, and normal builds do
/// not export this function or collect these timings.
#[cfg(feature = "scan-profile")]
#[uniffi::export]
pub fn take_scan_profile() -> String {
    timing::take().to_string()
}

fn parse_words(words: &[String]) -> Result<Vec<Word>, VisionError> {
    words
        .iter()
        .map(|w| {
            Word::from_bip39(w).ok_or_else(|| VisionError::Phrase {
                detail: format!("{w:?} is not a word of the list"),
            })
        })
        .collect()
}

/// Whether the words pass the BIP39 checksum: well formed, not
/// confirmed, since a wrong twelve-word phrase passes about one time in
/// sixteen. A word outside the list or a count the standard does not
/// allow fails.
#[uniffi::export]
pub fn checksum_passes(words: Vec<String>) -> bool {
    parse_words(&words).is_ok_and(|w| Bip39Checksum.passes(&w))
}

/// The list words starting with `prefix`, in list order, for a
/// correction field; the whole list for an empty prefix.
#[uniffi::export]
pub fn list_words(prefix: String) -> Vec<String> {
    let prefix = prefix.trim().to_lowercase();
    Word::all()
        .map(|w| w.as_str())
        .filter(|w| w.starts_with(&prefix))
        .map(str::to_owned)
        .collect()
}

/// One share as it is written onto its worksheet strip.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ShareText {
    /// The share number, 1 to 3.
    pub number: u8,
    /// One row per word in phrase order, the body of the worksheet's
    /// numbered line: the two checksum symbols, a space, the four
    /// letter symbols.
    pub rows: Vec<String>,
}

/// Splits a confirmed phrase into the 2-of-3 backup with the OS random
/// generator. Refuses a word outside the list or a phrase that fails the
/// checksum.
#[uniffi::export]
pub fn split_phrase(words: Vec<String>) -> Result<Vec<ShareText>, VisionError> {
    let words = parse_words(&words)?;
    if !Bip39Checksum.passes(&words) {
        return Err(VisionError::Phrase {
            detail: "the phrase does not pass the BIP39 checksum".into(),
        });
    }
    let mut rng = rand::rngs::OsRng.unwrap_err();
    Ok(penlock::split(&words, ShareCount::THREE, &mut rng)
        .iter()
        .map(|share| ShareText {
            number: share.index().number(),
            rows: share
                .words()
                .iter()
                .map(|&w| {
                    let s = symbols_to_string(w);
                    format!("{} {}", &s[..2], &s[2..])
                })
                .collect(),
        })
        .collect())
}

#[cfg(test)]
mod phrase_tests {
    use super::*;
    use penlock::share::parse_words as parse_rows;
    use penlock::{Share, ShareIndex};

    fn pack_native_word(word: &bitcoin_vision_words::WordBox) -> WordReading {
        let scan = ScanResult {
            found: bitcoin_vision_words::Found::Page,
            page: bitcoin_vision_words::PageScan {
                page_direction: None,
                width: 100,
                height: 100,
                words: vec![word.clone()],
                numbering: bitcoin_vision_words::numbering::Numbering::None,
                join_trials: Vec::new(),
                sources: Vec::new(),
            },
            regions: Vec::new(),
            #[cfg(feature = "extent-experiment")]
            extent: None,
        };
        WordReading::try_from(&scan.review().unwrap().words[0]).unwrap()
    }

    #[test]
    fn extent_provenance_and_original_read_material_survive_mobile_packing() {
        use bitcoin_vision_words::{ExtentParent as Parent, WordBox};
        let mut word = WordBox {
            quad: bitcoin_vision_words::detect::Quad([
                (10., 20.),
                (30., 20.),
                (30., 40.),
                (10., 40.),
            ]),
            crop: image::GrayImage::from_raw(
                2,
                3,
                vec![0, 10, 20, 30, 40, 255],
            )
            .unwrap(),
            ranked: vec![(0, 0.7), (1, 0.3)],
            selection: Some(
                bitcoin_vision_words::hybrid::select(
                    Some("abamdon"),
                    None,
                    &[(0, 0.7), (1, 0.3)],
                    0.85,
                    0.75,
                )
                .unwrap(),
            ),
            column_rank: 1,
            row_rank: 3,
            turned: false,
            raw: Some(bitcoin_vision_words::recogniser::LineRead {
                text: "abamdon".into(),
                confidence: 0.6,
            }),
            evidence: Default::default(),
            narrowed: false,
            stray: false,
            number: None,
            label: None,
            apart: false,
            joined_from: None,
            expanded_from: vec![Parent {
                word_index: 0,
                stray: false,
            }],
        };
        for pair in [false, true] {
            if pair {
                word.expanded_from.push(Parent {
                    word_index: 2,
                    stray: true,
                });
            }
            let packed = pack_native_word(&word);
            assert!(!packed.accepted && !packed.stray);
            assert!(packed.joined_from.is_empty());
            assert_eq!(packed.expanded_from.len(), if pair { 2 } else { 1 });
            assert_eq!(
                packed.expanded_from[0],
                ExtentParent {
                    word_index: 0,
                    stray: false
                }
            );
            if pair {
                assert_eq!(
                    packed.expanded_from[1],
                    ExtentParent {
                        word_index: 2,
                        stray: true
                    }
                );
            }
            assert_eq!(packed.read, "abandon");
            assert_eq!(packed.raw, "abamdon");
            assert_eq!(packed.ranked[0].probability, 0.7);
            assert_eq!(packed.corners, vec![10., 20., 30., 20., 30., 40., 10., 40.]);
            assert_eq!(
                image::load_from_memory(&packed.crop_png)
                    .unwrap()
                    .to_luma8(),
                word.crop
            );
        }
        // Normal native joins retain their own ABI field, not extent metadata.
        word.expanded_from.clear();
        // An unreadable occupied cell remains one uncertain app entry at its
        // geometric position, carrying exactly the native box and read pixels.
        word.evidence.cell = Some(bitcoin_vision_words::CellSupport {
            column: Some(0),
            row: Some(5),
            ordinal: Some(6),
            quad: word.quad.0,
            ink_pixels: 80,
            basis: "label_track_cell_and_word_ink",
        });
        word.number = Some(6);
        let cell = pack_native_word(&word);
        assert_eq!(cell.number, Some(6));
        assert!(!cell.stray && !cell.accepted);
        assert!(cell.joined_from.is_empty() && cell.expanded_from.is_empty());
        assert_eq!(cell.corners, vec![10., 20., 30., 20., 30., 40., 10., 40.]);
        assert_eq!(
            image::load_from_memory(&cell.crop_png)
                .unwrap()
                .to_luma8(),
            word.crop
        );
        word.evidence.cell = None;
        word.number = None;
        word.joined_from = Some([0, 2]);
        let packed = pack_native_word(&word);
        assert_eq!(packed.joined_from, vec![0, 2]);
        assert!(packed.expanded_from.is_empty());

        // Trimming is metadata, not another replacement/phrase entry. Each
        // verbatim read survives beside its own pixels through the ABI.
        word.raw.as_mut().unwrap().text = ". Hobby".into();
        word.evidence.original = Some(bitcoin_vision_words::OriginalRead {
            quad: bitcoin_vision_words::detect::Quad([
                (0., 20.),
                (30., 20.),
                (30., 40.),
                (0., 40.),
            ]),
            crop: image::GrayImage::new(4, 3),
            raw: bitcoin_vision_words::recogniser::LineRead {
                text: "9.Hobby".into(),
                confidence: 0.8,
            },
        });
        word.evidence.matching = Some(bitcoin_vision_words::MatchingRead {
            text: "Hobby".into(),
            original: true,
            removed_prefix_bytes: 2,
        });
        word.evidence.labels.push(bitcoin_vision_words::LabelRead {
            corners: word.quad.0,
            literal: "9.Hobby".into(),
            origin: "prefix".into(),
            ordinal: Some(9),
            dotted: true,
            ambiguous: false,
        });
        let packed = pack_native_word(&word);
        assert_eq!(packed.raw, ". Hobby");
        let original = packed.original_ocr.unwrap();
        assert_eq!(original.raw, "9.Hobby");
        assert_eq!(original.corners[0], 0.);
        assert_eq!(packed.corners[0], 10.);
        assert_eq!(
            image::load_from_memory(&original.crop_png)
                .unwrap()
                .width(),
            4
        );
        assert_eq!(
            image::load_from_memory(&packed.crop_png)
                .unwrap()
                .width(),
            2
        );
        let matching = packed.matching.unwrap();
        assert_eq!(matching.text, "Hobby");
        assert!(matching.original);
        assert_eq!(matching.removed_prefix_bytes, 2);
        assert_eq!(packed.labels[0].ordinal, Some(9));
        assert_eq!(packed.number, None);
    }

    #[cfg(feature = "scan-profile")]
    #[test]
    fn app_profile_export_drains_only_numeric_thread_samples() {
        take_scan_profile();
        {
            let _span = timing::span("mobile.init");
        }
        let report: serde_json::Value = serde_json::from_str(&take_scan_profile()).unwrap();
        assert_eq!(report["spans"][0]["name"], "mobile.init");
        assert_eq!(report["spans"][0]["calls"], 1);
        assert!(report["ocr_widths"].as_array().unwrap().is_empty());
        let empty: serde_json::Value = serde_json::from_str(&take_scan_profile()).unwrap();
        assert!(empty["spans"].as_array().unwrap().is_empty());
    }

    /// BIP39's own published test vector, so no page's phrase is in this
    /// repository that the photographer has not cleared for publication.
    fn phrase() -> Vec<String> {
        "legal winner thank year wave sausage worth useful legal winner thank yellow"
            .split(' ')
            .map(str::to_owned)
            .collect()
    }

    fn share_of(text: &ShareText) -> Share {
        let rows = parse_rows(text.rows.iter().map(String::as_str)).unwrap();
        Share::new(ShareIndex::new(text.number).unwrap(), rows)
    }

    #[test]
    fn the_checksum_is_a_filter() {
        assert!(checksum_passes(phrase()));
        let mut wrong = phrase();
        wrong[0] = "zoo".into();
        assert!(!checksum_passes(wrong));
        assert!(!checksum_passes(phrase()[..11].to_vec()));
        let mut off_list = phrase();
        off_list[3] = "years".into();
        assert!(!checksum_passes(off_list));
    }

    #[test]
    fn the_list_is_searched_by_prefix() {
        assert_eq!(list_words("zon".into()), vec!["zone".to_owned()]);
        assert_eq!(
            list_words(" ZO".into()),
            vec!["zone".to_owned(), "zoo".to_owned()]
        );
        assert_eq!(list_words(String::new()).len(), Word::COUNT);
    }

    #[test]
    fn any_two_shares_of_a_split_recover_the_phrase() {
        let shares = split_phrase(phrase()).unwrap();
        assert_eq!(
            shares.iter().map(|s| s.number).collect::<Vec<_>>(),
            [1, 2, 3]
        );
        assert_eq!(shares[0].rows.len(), 12);
        assert_eq!(shares[0].rows[0].len(), 7);
        assert_eq!(shares[0].rows[0].as_bytes()[2], b' ');
        let parsed: Vec<Share> = shares.iter().map(share_of).collect();
        for (a, b) in [(0, 1), (1, 2), (0, 2)] {
            let recovered = penlock::recover(&parsed[a], &parsed[b]).unwrap();
            assert_eq!(recovered.phrase().split(' ').collect::<Vec<_>>(), phrase());
        }
        let again = split_phrase(phrase()).unwrap();
        assert_ne!(again[0].rows, shares[0].rows);
    }

    #[test]
    fn a_phrase_failing_the_checksum_is_not_split() {
        let mut wrong = phrase();
        wrong[0] = "zoo".into();
        assert!(matches!(
            split_phrase(wrong),
            Err(VisionError::Phrase { .. })
        ));
        let mut off_list = phrase();
        off_list[0] = "legals".into();
        assert!(matches!(
            split_phrase(off_list),
            Err(VisionError::Phrase { .. })
        ));
    }
}

/// Twelve new words from the OS random generator, made the way bdk
/// makes a wallet's mnemonic.
#[uniffi::export]
pub fn new_phrase() -> Result<Vec<String>, VisionError> {
    let generated: GeneratedKey<Mnemonic, bdk_wallet::miniscript::Tap> =
        Mnemonic::generate((WordCount::Words12, Language::English)).map_err(|e| {
            VisionError::Phrase {
                detail: e.map_or_else(|| "no entropy".to_owned(), |e| e.to_string()),
            }
        })?;
    Ok(generated.words().map(str::to_owned).collect())
}

/// A wallet as it is saved and exported: public data only.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct WalletDescriptor {
    /// The master key fingerprint, eight hex digits.
    pub fingerprint: String,
    /// The BIP86 multipath descriptor with its checksum, as Sparrow
    /// imports it.
    pub descriptor: String,
}

/// The BIP86 wallet of `words` with no passphrase, derived the way
/// bdk's template does. Refuses a phrase that fails the checksum.
#[uniffi::export]
pub fn descriptor(words: Vec<String>) -> Result<WalletDescriptor, VisionError> {
    let phrase = |detail: String| VisionError::Phrase { detail };
    let words = parse_words(&words)?;
    let seed = penlock::oracle::seed(&words, "")
        .ok_or_else(|| phrase("the phrase does not pass the BIP39 checksum".into()))?;
    let master = Xpriv::new_master(Network::Bitcoin, &seed).map_err(|e| phrase(e.to_string()))?;
    let fingerprint = master.fingerprint(&Secp256k1::new()).to_string();
    let (external, _, _) = Bip86(master, KeychainKind::External)
        .build(NetworkKind::Main)
        .map_err(|e| phrase(e.to_string()))?;
    // bdk's template is one chain at a time; Sparrow takes both chains
    // in one descriptor, so the external one is rewritten multipath
    // and reparsed for its own checksum.
    let single = external.to_string();
    let bare = single.split('#').next().unwrap_or(&single);
    let multipath: Descriptor<DescriptorPublicKey> = bare
        .replacen("/0/*)", "/<0;1>/*)", 1)
        .parse()
        .map_err(|e: bdk_wallet::miniscript::Error| phrase(e.to_string()))?;
    Ok(WalletDescriptor {
        fingerprint,
        descriptor: multipath.to_string(),
    })
}
