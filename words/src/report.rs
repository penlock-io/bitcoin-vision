//! Saved decision transport over one completed scan, without a second read.

use crate::{ScanError, ScanResult};
use serde_json::{Value, json};

/// One named UTF-8 artifact from the scan that produced the review result.
#[derive(Clone, Debug, PartialEq)]
pub struct DecisionFile {
    /// Fixed relative filename within the saved decision directory.
    pub name: String,
    /// JSON or JSONL text, with no photo or crop bytes duplicated.
    pub text: String,
}

impl ScanResult {
    /// Projects the recorded processing decisions for this scan. This does
    /// not run another stage or infer a different word. The caller supplies
    /// only its already-applied image orientation and photo-up provenance.
    pub fn decision_files(
        &self,
        orientation: u8,
        photo_up_source: &str,
    ) -> Result<Vec<DecisionFile>, ScanError> {
        const PAGE: &str = "photo.png";
        let scan = &self.page;
        let regions = &self.regions;
        let boxes =
            crate::boxes::BoxScan::from_page(scan, regions).map_err(ScanError::Processing)?;
        let file = |name: &str, rows: Vec<Value>| DecisionFile {
            name: name.into(),
            text: rows.into_iter().map(|r| r.to_string() + "\n").collect(),
        };
        let initial = scan.initial_traversal();
        let order = &initial.indices;
        let sources = scan.sources.iter().map(|s| {
            use crate::sources::Outcome;
            let outcome = match &s.outcome {
                Outcome::Parts(parts)=>json!({"kind":"parts","parts":parts.iter().map(|p| json!({"part":p.part,"quad":p.quad.0,"word_index":p.word_index})).collect::<Vec<_>>()}),
                Outcome::Empty(reason)=>json!({"kind":"empty","reason":reason.as_str()}),
                Outcome::Rescued{reason,word_index}=>json!({"kind":"rescued","reason":reason.as_str(),"word_index":word_index}),
            };
            json!({"detector":s.detector,"quad":s.quad.0,"outcome":outcome,
                "decision":s.decision.as_ref().map(|d| json!({"reason":d.reason(),
                    "scale":d.scale().map(|s| json!({"height":s.height,"supports":s.supports})),
                    "owner":d.owner().map(|o| json!({"source":o.source,"part":o.part,"word_index":o.word_index(&scan.sources)})),
                    "union_geometry":match d {
                        crate::fragments::Decision::Tiny { ownership:crate::fragments::Ownership::Ending {union,footprint,..},.. } => Some(json!({"quad":union.0,"footprint":footprint.0})),
                        _=>None,
                    }})),
                "union":s.union.as_ref().map(|u| json!({"word_index":u.word_index,"selected":u.selected,"reason":u.reason}))})
        }).collect::<Vec<_>>();
        let mut numbering = match &scan.numbering {
            crate::numbering::Numbering::None => json!({"state":"none"}),
            crate::numbering::Numbering::Inconsistent { detail } => {
                json!({"state":"inconsistent","detail":detail})
            }
            crate::numbering::Numbering::Held {
                count,
                missing,
                out_of_place,
                unresolved,
                ..
            } => {
                json!({"state":"held","count":count,"missing":missing,"out_of_place":out_of_place,"unresolved":unresolved})
            }
        };
        numbering["page"] = json!(PAGE);
        numbering["list_numbered"] =
            json!(scan.list_mode() == crate::numbering::dotted::ListMode::Numbered);
        Ok(vec![
            file("manifest.json",vec![json!({"schema":"penlock-phone-decisions-v1","page":PAGE,
                "coordinate_frame":"canonical_photo","orientation_applied":orientation,"layout":if self.found == crate::Found::Page {"page"} else {"word_sheet"},
                "photo_up_source":photo_up_source,
                "page_writing_direction":scan.page_direction.as_ref().and_then(|d| d.decisions.as_ref()).map(|d|d.to_json()),
                "package_version":env!("CARGO_PKG_VERSION"),"code_revision":option_env!("VISION_BUILD_REVISION"),
                "word_count":scan.words.len(),"scope":"native scan before user edits"})]),
            file("final-boxes.jsonl",vec![boxes.to_json(PAGE)]),
            file("word-links.jsonl",regions.iter().filter(|r| !scan.words[r.word_index as usize].stray).map(|r| json!({"schema":"penlock-box-word-links-v1","page":PAGE,"box_id":r.id,"word_index":r.word_index})).collect()),
            file("readings.jsonl",scan.words.iter().enumerate().map(|(i,w)| json!({"page":PAGE,"file":format!("{PAGE}~w{i}.png"),
                "kept":!w.stray,"corners":w.quad.0,"ranked":w.ranked.iter().take(5).filter_map(|&(index,p)| crate::Word::from_index(index as u16).map(|word| json!([word.as_str(),p]))).collect::<Vec<_>>(),
                "raw":w.raw.as_ref().map(|r| vec![&r.text]),"raw_confidence":w.raw.as_ref().map(|r| r.confidence),
                "selection":w.selection.as_ref().map(|s| s.diagnostic()),"verdict":format!("{:?}",w.verdict()).to_lowercase(),
                "label":w.label,"number":w.number,"apart":w.apart,"narrowed":w.narrowed,"evidence":w.evidence.to_json(),
                "joined_from":w.joined_from,"expanded_from":w.expanded_from.iter().map(|p| p.word_index).collect::<Vec<_>>(),
                "original_crop":w.evidence.original.as_ref().map(|_| format!("original-crops/{PAGE}~w{i}.png"))})).collect()),
            file("sources.jsonl",vec![json!({"page":PAGE,"sources":sources})]),
            file("numbering.jsonl",vec![numbering]),
            file("ordering.jsonl",vec![json!({"page":PAGE,"initial_order":initial.order.as_str(),
                "requires_review":initial.requires_review,"basis":initial.basis,
                "layout_support":initial.layout_support.to_json(),
                "columns_pass":initial.columns_pass,"rows_pass":initial.rows_pass,"kept_indices":order.iter().copied().filter(|&i| !scan.words[i].stray).collect::<Vec<_>>()})]),
            file("joins.jsonl",vec![json!({"page":PAGE,"trials":scan.join_trials.iter().map(|t| json!({"column":t.column,"row":t.row,"parents":t.parents,"reason":t.reason,
                "read":t.read.as_ref().map(|r| json!({"top":r.top,"probability":r.probability,"margin":r.margin,"pick":r.pick,"kept":r.kept}))})).collect::<Vec<_>>()})]),
        ])
    }
}
