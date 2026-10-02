//! Geometry-only detector provenance. Unread ink is never a WordReading.

use bitcoin_vision_words::review::ReviewSource;

/// One original split part, whether or not it was eligible for reading.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct DetectionPart {
    /// Stable index within the raw detection.
    pub part: u32,
    /// Original polygon in canonical photo pixels.
    pub corners: Vec<f32>,
    /// Original reading in PhraseScan.words; absent for suppressed non-word ink.
    pub word_index: Option<u32>,
}

/// A fragment's geometric owner, with its current original-reading link.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct DetectionOwner {
    /// Stable raw detector identity, not a word index.
    pub detector_id: u32,
    /// Stable part ID; absent for a whole-raw recovery.
    pub part: Option<u32>,
    /// Current original reading in PhraseScan.words.
    pub word_index: Option<u32>,
}

/// A detached-ending proposal and its optional actual reading.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct DetectionUnion {
    /// Full union polygon; never the geometry of the original parent's reading.
    pub corners: Vec<f32>,
    /// Rounded, margin-bearing read footprint checked against neighbors.
    pub read_footprint: Vec<f32>,
    /// Actual union reading in PhraseScan.words, absent if not read.
    pub word_index: Option<u32>,
    /// Whether the scanner initially selected this alternative.
    pub selected: bool,
    /// Native selection or refusal reason; the app does not re-evaluate it.
    pub reason: String,
}

/// Every accepted raw detector source, including geometry-only excluded ink.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct DetectionSource {
    /// Stable index in accepted detector output.
    pub detector_id: u32,
    /// Full raw polygon in the same frame as the review photo.
    pub corners: Vec<f32>,
    /// All original split parts, including suppressed ones without readings.
    pub parts: Vec<DetectionPart>,
    /// Why segmentation returned no parts, including a later rescued source.
    pub empty_reason: Option<String>,
    /// Actual whole-raw recovery reading; absent if none was made.
    pub recovered_word: Option<u32>,
    /// Native geometry decision, absent on fixed worksheet fields.
    pub decision: Option<String>,
    /// Measured local writing height, when supported.
    pub local_height: Option<f32>,
    /// Independent raw detector identities supporting the local scale.
    pub support_ids: Vec<u32>,
    /// Unique native owner of excluded ink, when established.
    pub owner: Option<DetectionOwner>,
    /// Optional detached-ending proposal, with its real reading link.
    pub union: Option<DetectionUnion>,
}

fn corners(quad: &[(f32, f32); 4]) -> Vec<f32> {
    quad.iter().flat_map(|&(x, y)| [x, y]).collect()
}

pub(crate) fn pack(sources: &[ReviewSource]) -> Vec<DetectionSource> {
    sources
        .iter()
        .map(|source| {
            DetectionSource {
                detector_id: source.detector_id,
                corners: corners(&source.quad),
                parts: source
                    .parts
                    .iter()
                    .map(|p| DetectionPart {
                        part: p.part,
                        corners: corners(&p.quad),
                        word_index: p.word_index,
                    })
                    .collect(),
                empty_reason: source.empty_reason.clone(),
                recovered_word: source.recovered_word,
                decision: source.decision.clone(),
                local_height: source.local_height,
                support_ids: source.support_ids.clone(),
                owner: source.owner.as_ref().map(|owner| DetectionOwner {
                    detector_id: owner.detector_id,
                    part: owner.part,
                    word_index: owner.word_index,
                }),
                union: source.union.as_ref().map(|union| DetectionUnion {
                    corners: corners(&union.quad),
                    read_footprint: corners(&union.read_footprint),
                    word_index: union.word_index,
                    selected: union.selected,
                    reason: union.reason.clone(),
                }),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitcoin_vision_words::review::{ReviewOwner, ReviewPart, ReviewUnion};

    #[test]
    fn geometry_only_and_rescued_sources_keep_distinct_links_through_packing() {
        let parent = [(10., 20.), (70., 20.), (70., 40.), (10., 40.)];
        let tiny = [(71., 25.), (75., 25.), (75., 30.), (71., 30.)];
        let union = [(10., 20.), (75., 20.), (75., 40.), (10., 40.)];
        let sources = vec![
            ReviewSource {
                detector_id: 8,
                quad: parent,
                parts: Vec::new(),
                empty_reason: Some("no_ink_after_rules".into()),
                recovered_word: Some(3),
                decision: None,
                local_height: None,
                support_ids: Vec::new(),
                owner: None,
                union: None,
            },
            ReviewSource {
                detector_id: 12,
                quad: tiny,
                parts: vec![ReviewPart {
                    part: 2,
                    quad: tiny,
                    word_index: None,
                }],
                empty_reason: None,
                recovered_word: None,
                decision: Some("tiny".into()),
                local_height: Some(20.),
                support_ids: vec![8],
                owner: Some(ReviewOwner {
                    detector_id: 8,
                    part: None,
                    word_index: Some(3),
                }),
                union: Some(ReviewUnion {
                    quad: union,
                    read_footprint: union,
                    word_index: Some(4),
                    selected: false,
                    reason: "uncertain".into(),
                }),
            },
        ];
        let packed = pack(&sources);
        assert_eq!(packed[0].recovered_word, Some(3));
        assert!(packed[0].parts.is_empty());
        assert_eq!(packed[1].parts[0].word_index, None);
        assert_eq!(packed[1].corners, corners(&tiny));
        assert_eq!(packed[1].support_ids, vec![8]);
        assert_eq!(
            packed[1].owner,
            Some(DetectionOwner {
                detector_id: 8,
                part: None,
                word_index: Some(3)
            })
        );
        let alternative = packed[1].union.as_ref().unwrap();
        assert_eq!(alternative.word_index, Some(4));
        assert_eq!(alternative.corners, corners(&union));
        assert!(!alternative.selected);
        assert_eq!(alternative.reason, "uncertain");
    }
}
