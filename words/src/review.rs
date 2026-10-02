//! Detailed, immutable review data projected from one finished scan.
//!
//! This is the app-facing view of saved evidence. It neither runs a stage nor
//! chooses a word or an order. In particular, it does not expose the native
//! detector, number fitter, page layout, or crop reader as callable APIs.

use crate::fragments::{Decision, Ownership};
use crate::numbering::{Numbering, dotted::ListMode};
use crate::phrase::WordBox;
use crate::sources::{Outcome, RawSource};
use crate::words::Verdict;
use crate::{Found, ScanError, ScanResult, Word};
use image::ImageFormat;

/// The whole finished page, including inactive observations for restoration.
#[derive(Clone, Debug)]
pub struct ReviewPage {
    /// Whether the scan found a generic page or a registered sheet.
    pub found: Found,
    /// Canonical photo width.
    pub width: u32,
    /// Canonical photo height.
    pub height: u32,
    /// Observations in native column order, including inactive alternatives.
    pub words: Vec<ReviewWord>,
    /// Observation indices in column order, including inactive alternatives.
    pub columns: Vec<u32>,
    /// Observation indices in row order, including inactive alternatives.
    pub rows: Vec<u32>,
    /// Observation indices in label order, including inactive alternatives.
    pub numbered: Vec<u32>,
    /// Whether the kept column-order words pass BIP39 checksum.
    pub columns_pass: bool,
    /// Whether the kept row-order words pass BIP39 checksum.
    pub rows_pass: bool,
    /// Whether the kept number-order words pass BIP39 checksum.
    pub numbered_pass: bool,
    /// Whether dotted-label evidence establishes a numbered list.
    pub list_numbered: bool,
    /// What the observed labels established, independently of checksum.
    pub numbering: ReviewNumbering,
    /// `numbers`, `rows`, or `columns` according to the native stage.
    pub initial_order: &'static str,
    /// Whether that order needs a human check.
    pub order_requires_review: bool,
    /// Native reason for the initial traversal.
    pub order_basis: &'static str,
    /// Raw detector provenance, including geometry-only observations.
    pub sources: Vec<ReviewSource>,
}

/// One observed word and its exact model crop.
#[derive(Clone, Debug)]
pub struct ReviewWord {
    /// Four corners in canonical photo pixels.
    pub quad: [(f32, f32); 4],
    /// The five saved classifier candidates in model rank order.
    pub ranked: Vec<(&'static str, f32)>,
    /// Whether the native calibration accepted the selected word.
    pub accepted: bool,
    /// Selected BIP39 word, absent on an unread geometry-only observation.
    pub selected: Option<&'static str>,
    /// Literal OCR of the selected crop, if OCR ran.
    pub raw: Option<String>,
    /// Exact grayscale crop bytes encoded losslessly as PNG.
    pub crop_png: Vec<u8>,
    /// Pre-cut OCR evidence when a crop was narrowed.
    pub original: Option<ReviewOriginal>,
    /// Text chosen for word matching, distinct from literal OCR.
    pub matching: Option<ReviewMatching>,
    /// All observed label readings, including uncertain ones.
    pub labels: Vec<ReviewLabel>,
    /// Whether label observations conflict.
    pub label_conflict: bool,
    /// Whether the native stage initially excluded this observation.
    pub stray: bool,
    /// Trusted ordinal, if the native number fitter assigned one.
    pub number: Option<u32>,
    /// Whether this word was excluded as remote from the phrase.
    pub apart: bool,
    /// Original observations replaced by a native join.
    pub joined_from: Vec<u32>,
    /// Original observations replaced by an extent expansion.
    pub expanded_from: Vec<ReviewParent>,
}

/// An original word retained behind an extent replacement.
#[derive(Clone, Debug)]
pub struct ReviewParent {
    /// Index into all returned observations.
    pub word_index: u32,
    /// Keep state before the extent replacement.
    pub stray: bool,
}

/// The exact OCR crop retained before an adopted narrowing.
#[derive(Clone, Debug)]
pub struct ReviewOriginal {
    /// Original corners in canonical photo pixels.
    pub quad: [(f32, f32); 4],
    /// Exact original grayscale crop, encoded as PNG.
    pub crop_png: Vec<u8>,
    /// Literal read of that original crop.
    pub raw: String,
}

/// Selection input chosen separately from literal OCR.
#[derive(Clone, Debug)]
pub struct ReviewMatching {
    /// Matching text before ordinary normalization.
    pub text: String,
    /// Whether this refers to the original, pre-cut crop.
    pub original: bool,
    /// Leading UTF-8 bytes removed from the owning literal.
    pub removed_prefix_bytes: u32,
}

/// One observed label, not necessarily a trusted ordinal.
#[derive(Clone, Debug)]
pub struct ReviewLabel {
    /// Source geometry in canonical photo pixels.
    pub quad: [(f32, f32); 4],
    /// Verbatim OCR text including punctuation.
    pub literal: String,
    /// Whole prefix, token, standalone, or beside-word source.
    pub origin: String,
    /// Exact positive digits when available.
    pub ordinal: Option<u32>,
    /// Whether mandatory dotted-label evidence was present.
    pub dotted: bool,
    /// Whether more than one word could own this label.
    pub ambiguous: bool,
}

/// Page-wide label interpretation.
#[derive(Clone, Debug)]
pub enum ReviewNumbering {
    /// Too little evidence for a trusted sequence.
    None,
    /// A trusted numbered run with its gaps and contradictions.
    Held {
        /// Highest number in the run.
        count: u32,
        /// Numbers no observed word carries.
        missing: Vec<u32>,
        /// Numbers out of physical order.
        out_of_place: Vec<u32>,
        /// Observations with labels not assigned a run number.
        unresolved: Vec<u32>,
    },
    /// Enough observations to establish that the labels conflict.
    Inconsistent {
        /// Stable explanation of the conflict.
        detail: String,
    },
}

/// One original detector source and its geometry-only decisions.
#[derive(Clone, Debug)]
pub struct ReviewSource {
    /// Stable index in accepted detector output.
    pub detector_id: u32,
    /// Original polygon in canonical photo pixels.
    pub quad: [(f32, f32); 4],
    /// Original split parts, including suppressed geometry.
    pub parts: Vec<ReviewPart>,
    /// Why no split part was returned, if relevant.
    pub empty_reason: Option<String>,
    /// Actual whole-raw recovery observation, if one was read.
    pub recovered_word: Option<u32>,
    /// Native geometry decision name.
    pub decision: Option<String>,
    /// Measured local writing height, when supported.
    pub local_height: Option<f32>,
    /// Independent raw detector identities supporting the local scale.
    pub support_ids: Vec<u32>,
    /// Geometric owner of excluded ink, when unique.
    pub owner: Option<ReviewOwner>,
    /// Detached-ending union proposal and actual reading link, if any.
    pub union: Option<ReviewUnion>,
}

/// One split part of a raw detector source.
#[derive(Clone, Debug)]
pub struct ReviewPart {
    /// Stable part index within its raw source.
    pub part: u32,
    /// Original polygon.
    pub quad: [(f32, f32); 4],
    /// Original reading index, absent for suppressed ink.
    pub word_index: Option<u32>,
}

/// Geometric owner of excluded detector ink.
#[derive(Clone, Debug)]
pub struct ReviewOwner {
    /// Owning raw detector identity.
    pub detector_id: u32,
    /// Owning part, or whole-raw owner.
    pub part: Option<u32>,
    /// Actual word observation, if read.
    pub word_index: Option<u32>,
}

/// A detached-ending union proposal and its actual read status.
#[derive(Clone, Debug)]
pub struct ReviewUnion {
    /// Union polygon in canonical photo pixels.
    pub quad: [(f32, f32); 4],
    /// Rounded read footprint checked against neighbors.
    pub read_footprint: [(f32, f32); 4],
    /// Actual alternative reading, absent if not read.
    pub word_index: Option<u32>,
    /// Whether selected over the original parent.
    pub selected: bool,
    /// Native selection or refusal reason.
    pub reason: String,
}

/// Selected final boxes in stable-ID order, without word text.
#[derive(Clone, Debug, PartialEq)]
pub struct ReviewBoxes {
    /// Canonical photo width.
    pub width: u32,
    /// Canonical photo height.
    pub height: u32,
    /// The authoritative selected geometry.
    pub boxes: Vec<ReviewBox>,
}

/// One selected final box with its stable scan identity.
#[derive(Clone, Debug, PartialEq)]
pub struct ReviewBox {
    /// Stable identity, not a phrase position.
    pub id: u32,
    /// Four corners in canonical photo pixels.
    pub quad: [(f32, f32); 4],
}

impl ScanResult {
    /// Projects only the final selected boxes from this result's saved ID map.
    /// Incomplete, duplicate, or out-of-range maps are rejected.
    pub fn selected_boxes(&self) -> Result<ReviewBoxes, ScanError> {
        let boxes = crate::boxes::BoxScan::from_page(&self.page, &self.regions)
            .map_err(ScanError::Processing)?;
        Ok(ReviewBoxes {
            width: boxes.width,
            height: boxes.height,
            boxes: boxes
                .boxes
                .into_iter()
                .map(|b| ReviewBox {
                    id: b.id,
                    quad: b.quad.0,
                })
                .collect(),
        })
    }

    /// Projects saved review data, including exact model crops, without rerunning
    /// detection, recognition, selection, or ordering.
    pub fn review(&self) -> Result<ReviewPage, ScanError> {
        let scan = &self.page;
        let words = scan
            .words
            .iter()
            .map(review_word)
            .collect::<Result<_, _>>()?;
        let initial = scan.initial_traversal();
        let numbering = match &scan.numbering {
            Numbering::None => ReviewNumbering::None,
            Numbering::Held {
                count,
                missing,
                out_of_place,
                unresolved,
                ..
            } => ReviewNumbering::Held {
                count: *count,
                missing: missing.clone(),
                out_of_place: out_of_place.clone(),
                unresolved: unresolved.iter().map(|&i| i as u32).collect(),
            },
            Numbering::Inconsistent { detail } => ReviewNumbering::Inconsistent {
                detail: detail.clone(),
            },
        };
        Ok(ReviewPage {
            found: self.found,
            width: scan.width,
            height: scan.height,
            columns: (0..scan.words.len()).map(|i| i as u32).collect(),
            rows: scan.by_rows().into_iter().map(|i| i as u32).collect(),
            numbered: scan.by_numbers().into_iter().map(|i| i as u32).collect(),
            columns_pass: initial.columns_pass,
            rows_pass: initial.rows_pass,
            numbered_pass: initial.numbered_pass,
            list_numbered: scan.list_mode() == ListMode::Numbered,
            numbering,
            initial_order: initial.order.as_str(),
            order_requires_review: initial.requires_review,
            order_basis: initial.basis,
            sources: review_sources(&scan.sources),
            words,
        })
    }
}

fn png(crop: &image::GrayImage) -> Result<Vec<u8>, ScanError> {
    let mut bytes = Vec::new();
    crop.write_to(&mut std::io::Cursor::new(&mut bytes), ImageFormat::Png)
        .map_err(|error| ScanError::Processing(format!("encoding exact review crop: {error}")))?;
    Ok(bytes)
}

fn review_word(word: &WordBox) -> Result<ReviewWord, ScanError> {
    let original = word
        .evidence
        .original
        .as_ref()
        .map(|read| {
            Ok::<_, ScanError>(ReviewOriginal {
                quad: read.quad.0,
                crop_png: png(&read.crop)?,
                raw: read.raw.text.clone(),
            })
        })
        .transpose()?;
    Ok(ReviewWord {
        quad: word.quad.0,
        ranked: word
            .ranked
            .iter()
            .take(5)
            .filter_map(|&(i, p)| Word::from_index(i as u16).map(|word| (word.as_str(), p)))
            .collect(),
        accepted: word.verdict() == Verdict::Accept,
        selected: word
            .pick()
            .and_then(|i| Word::from_index(i as u16))
            .map(|w| w.as_str()),
        raw: word.raw.as_ref().map(|read| read.text.clone()),
        crop_png: png(&word.crop)?,
        original,
        matching: word.evidence.matching.as_ref().map(|m| ReviewMatching {
            text: m.text.clone(),
            original: m.original,
            removed_prefix_bytes: m.removed_prefix_bytes as u32,
        }),
        labels: word
            .evidence
            .labels
            .iter()
            .map(|label| ReviewLabel {
                quad: label.corners,
                literal: label.literal.clone(),
                origin: label.origin.clone(),
                ordinal: label.ordinal,
                dotted: label.dotted,
                ambiguous: label.ambiguous,
            })
            .collect(),
        label_conflict: word.evidence.conflict,
        stray: word.stray,
        number: word.number,
        apart: word.apart,
        joined_from: word
            .joined_from
            .into_iter()
            .flatten()
            .map(|i| i as u32)
            .collect(),
        expanded_from: word
            .expanded_from
            .iter()
            .map(|p| ReviewParent {
                word_index: p.word_index as u32,
                stray: p.stray,
            })
            .collect(),
    })
}

fn review_sources(sources: &[RawSource]) -> Vec<ReviewSource> {
    sources
        .iter()
        .map(|source| {
            let decision = source.decision.as_ref();
            let (empty_reason, recovered_word) = match source.outcome {
                Outcome::Parts(_) => (None, None),
                Outcome::Empty(reason) => (Some(reason.as_str().to_owned()), None),
                Outcome::Rescued { reason, word_index } => {
                    (Some(reason.as_str().to_owned()), Some(word_index as u32))
                }
            };
            ReviewSource {
                detector_id: source.detector as u32,
                quad: source.quad.0,
                parts: source
                    .parts()
                    .iter()
                    .map(|p| ReviewPart {
                        part: p.part as u32,
                        quad: p.quad.0,
                        word_index: p.word_index.map(|i| i as u32),
                    })
                    .collect(),
                empty_reason,
                recovered_word,
                decision: decision.map(|d| d.reason().to_owned()),
                local_height: decision.and_then(Decision::scale).map(|s| s.height),
                support_ids: decision
                    .and_then(Decision::scale)
                    .map(|s| {
                        s.supports
                            .iter()
                            .map(|&i| sources[i].detector as u32)
                            .collect()
                    })
                    .unwrap_or_default(),
                owner: decision.and_then(Decision::owner).map(|o| ReviewOwner {
                    detector_id: sources[o.source].detector as u32,
                    part: o.part.map(|p| p as u32),
                    word_index: o.word_index(sources).map(|i| i as u32),
                }),
                union: match decision {
                    Some(Decision::Tiny {
                        ownership:
                            Ownership::Ending {
                                union, footprint, ..
                            },
                        ..
                    }) => Some(ReviewUnion {
                        quad: union.0,
                        read_footprint: footprint.0,
                        word_index: source
                            .union
                            .as_ref()
                            .and_then(|u| u.word_index)
                            .map(|i| i as u32),
                        selected: source.union.as_ref().is_some_and(|u| u.selected),
                        reason: source
                            .union
                            .as_ref()
                            .map_or("not_read", |u| u.reason)
                            .to_owned(),
                    }),
                    _ => None,
                },
            }
        })
        .collect()
}
