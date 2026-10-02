//! Explicit saved-stage transport. No image encoding, recognition or I/O here.
use crate::{PhotoUpSource, PhraseScan, VisionError};
use bitcoin_vision_words::ScanResult;

/// One named UTF-8 stage artifact, created only by the diagnostic scan method.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct DiagnosticFile {
    /// Fixed relative filename within the saved stage directory.
    pub name: String,
    /// JSON or JSONL containing the actual native observations.
    pub text: String,
}

/// Normal review result plus opt-in saved processing evidence for that same call.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct DiagnosedScan {
    /// Unchanged review words, crops, orders and geometry.
    pub scan: PhraseScan,
    /// No photo pixels or second encoded crop copies; use scan.words' PNGs.
    pub files: Vec<DiagnosticFile>,
}

pub(crate) fn pack(
    scan: &ScanResult,
    orientation: u8,
    photo_up: PhotoUpSource,
) -> Result<Vec<DiagnosticFile>, VisionError> {
    scan.decision_files(orientation, photo_up.source())
        .map(|files| files.into_iter().map(|file| DiagnosticFile {
            name: file.name,
            text: file.text,
        }).collect())
        .map_err(|error| VisionError::Scan { detail: error.to_string() })
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitcoin_vision_words::{DecisionTrace, WordBox};
    use bitcoin_vision_words::PageScan;
    use bitcoin_vision_words::progress::FinalRegion;
    use serde_json::{Value, json};

    fn native_result(page: &PageScan, regions: &[FinalRegion]) -> ScanResult {
        ScanResult {
            found: bitcoin_vision_words::Found::Page,
            page: page.clone(),
            regions: regions.to_vec(),
            #[cfg(feature = "extent-experiment")]
            extent: None,
        }
    }

    fn pack_native_page(page: &PageScan) -> PhraseScan {
        crate::pack_scan(&native_result(page, &[])).unwrap()
    }

    fn fixture() -> PageScan {
        let word = WordBox {
            quad: bitcoin_vision_words::detect::Quad([
                (10., 20.),
                (50., 20.),
                (50., 40.),
                (10., 40.),
            ]),
            crop: image::GrayImage::from_raw(
                2,
                3,
                vec![0, 20, 40, 60, 80, 255],
            )
            .unwrap(),
            ranked: vec![(0, 0.9), (1, 0.1)],
            selection: Some(
                bitcoin_vision_words::hybrid::select(
                    Some("abandon"),
                    None,
                    &[(0, 0.9), (1, 0.1)],
                    0.85,
                    0.75,
                )
                .unwrap(),
            ),
            column_rank: 0,
            row_rank: 0,
            turned: false,
            raw: Some(bitcoin_vision_words::recogniser::LineRead {
                text: "abandon".into(),
                confidence: 0.6,
            }),
            evidence: Default::default(),
            narrowed: false,
            stray: false,
            number: None,
            label: None,
            apart: false,
            joined_from: None,
            expanded_from: vec![],
        };
        let mut excluded = word.clone();
        excluded.stray = true;
        excluded.column_rank = 1;
        excluded.row_rank = 1;
        PageScan {
            page_direction: None,
            width: 100,
            height: 100,
            words: vec![word, excluded],
            numbering: bitcoin_vision_words::numbering::Numbering::None,
            join_trials: vec![],
            sources: vec![],
        }
    }

    #[test]
    fn ambiguous_order_review_requirement_survives_mobile_packing() {
        let mut scan = fixture();
        scan.words[1].stray = false;
        scan.words[0].row_rank = 1;
        scan.words[1].row_rank = 0;
        let result = pack_native_page(&scan);
        assert!(result.order_requires_review);
        assert_eq!(result.order_basis, "equal_dimensions_unverified_layout");
        assert_eq!(result.initial_order, crate::InitialOrder::Columns);
        scan.words[0].row_rank = 0;
        scan.words[1].row_rank = 1;
        let result = pack_native_page(&scan);
        assert!(!result.order_requires_review);
        assert_eq!(result.order_basis, "same_retained_traversal");
    }

    #[test]
    fn saved_transport_preserves_review_and_explicit_identity_without_reading() {
        let mut scan = fixture();
        let regions = [
            FinalRegion {
                id: 42,
                word_index: 1,
            },
            FinalRegion {
                id: 91,
                word_index: 0,
            },
        ];
        let normal = pack_native_page(&scan);
        let plain = pack(&native_result(&scan, &regions), 6, PhotoUpSource::Camera).unwrap();
        scan.words[0].evidence.decisions = Some(DecisionTrace::default());
        let traced = pack_native_page(&scan);
        assert_eq!(
            normal, traced,
            "diagnostics must not alter review bytes/order/selection"
        );
        let files = pack(&native_result(&scan, &regions), 6, PhotoUpSource::Camera).unwrap();
        assert_eq!(files.len(), 8);
        let rows = |files: &[DiagnosticFile], name: &str| -> Vec<Value> {
            files
                .iter()
                .find(|f| f.name == name)
                .unwrap()
                .text
                .lines()
                .map(|s| serde_json::from_str(s).unwrap())
                .collect()
        };
        let readings = rows(&files, "readings.jsonl");
        assert_eq!(
            readings.len(),
            2,
            "inactive observations keep their original indices"
        );
        assert_eq!(readings[0]["raw"], json!(["abandon"]));
        assert_eq!(
            readings[0]["selection"],
            scan.words[0].selection.as_ref().unwrap().diagnostic()
        );
        assert_eq!(
            readings[0]["evidence"]["decisions"],
            scan.words[0].evidence.decisions.as_ref().unwrap().to_json()
        );
        assert!(
            rows(&plain, "readings.jsonl")[0]["evidence"]
                .get("decisions")
                .is_none()
        );
        assert_eq!(readings[1]["kept"], false);
        assert_eq!(
            rows(&files, "word-links.jsonl"),
            vec![
                json!({"schema":"penlock-box-word-links-v1","page":"photo.png","box_id":91,"word_index":0})
            ]
        );
        let boxes = rows(&files, "final-boxes.jsonl");
        assert_eq!(boxes[0]["boxes"].as_array().unwrap().len(), 1);
        assert_eq!(boxes[0]["boxes"][0]["id"], 91);
        assert_eq!(
            rows(&files, "ordering.jsonl")[0]["kept_indices"],
            json!([0])
        );
        assert_eq!(
            rows(&files, "ordering.jsonl")[0]["requires_review"],
            json!(traced.order_requires_review)
        );
        assert_eq!(
            rows(&files, "ordering.jsonl")[0]["basis"],
            json!(traced.order_basis)
        );
        assert_eq!(rows(&files, "manifest.json")[0]["orientation_applied"], 6);
        assert_eq!(
            rows(&files, "manifest.json")[0]["photo_up_source"],
            "camera"
        );
        assert_eq!(
            image::load_from_memory(&traced.words[0].crop_png)
                .unwrap()
                .to_luma8(),
            scan.words[0].crop
        );
    }

    #[test]
    fn saved_transport_refuses_incomplete_or_conflicting_region_links() {
        let scan = fixture();
        for regions in [
            vec![],
            vec![FinalRegion {
                id: 1,
                word_index: 0,
            }],
            vec![
                FinalRegion {
                    id: 1,
                    word_index: 0,
                },
                FinalRegion {
                    id: 1,
                    word_index: 1,
                },
            ],
            vec![
                FinalRegion {
                    id: 1,
                    word_index: 0,
                },
                FinalRegion {
                    id: 2,
                    word_index: 5,
                },
            ],
        ] {
            assert!(pack(&native_result(&scan, &regions), 1, PhotoUpSource::Unknown).is_err());
        }
    }

    #[test]
    fn empty_page_still_exports_the_page_direction_and_separate_photo_transform() {
        let mut scan = fixture();
        scan.words.clear();
        scan.sources.clear();
        scan.page_direction = Some(
            bitcoin_vision_words::page_frame::PageAxis::from_detections(&[])
                .resolve(
                    &image::RgbImage::new(0, 0),
                    bitcoin_vision_words::page_frame::PhotoUp::Unknown,
                    None,
                    0.15,
                    true,
                )
                .unwrap(),
        );
        let files = pack(&native_result(&scan, &[]), 1, PhotoUpSource::Unknown).unwrap();
        let manifest: Value = serde_json::from_str(
            &files
                .iter()
                .find(|f| f.name == "manifest.json")
                .unwrap()
                .text,
        )
        .unwrap();
        assert_eq!(manifest["orientation_applied"], 1);
        assert_eq!(manifest["photo_up_source"], "unknown");
        let decision = &manifest["page_writing_direction"]["events"][0];
        assert_eq!(
            decision["axis_reason"],
            "no_valid_detections_canonical_horizontal"
        );
        assert_eq!(decision["orientation_reads"], 0);
    }
}
