//! All-vocabulary log10/edit selection with identity-bound confidence.
use super::{CURRENT, distance, normalise};
use crate::vocabulary::Word;

/// The longest word the list holds. A read longer than this is not a
/// misreading of a list word, it is something else on the page, and no
/// classifier confidence can make it one. Pinned by `the_list_has_no_word_longer`.
const LONGEST_WORD: usize = 8;
use crate::words::{Verdict, verdict};

/// Which evidence path selected the word.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Branch {
    /// An exact normalized OCR word, independent of candidate coverage.
    ExactText,
    /// Joint probability/distance comparison of eligible candidates.
    Joint,
    /// No text or no eligible alternative to classifier top.
    ModelFallback,
}

/// Provenance of the text used for the selection, not a display literal rewrite.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextSource {
    /// No recognizer supplied text.
    Absent,
    /// The final crop's literal OCR text.
    Literal,
    /// Separately owned matching text takes precedence over the literal.
    Matching,
}

/// Classifier evidence for the selected identity, never borrowed from another word.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Support {
    /// The word occurs in the supplied ranking; rank is one-based.
    Ranked {
        /// One-based position in the supplied ranking.
        rank: usize,
        /// Recorded probability, including a recorded zero.
        probability: f32,
    },
    /// No probability for this word was supplied. This is not zero.
    Unavailable {
        /// How many ranked entries were actually supplied.
        supplied_rank_count: usize,
    },
}

/// Confirmation evidence for the word selected by this same decision.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Confirmation {
    /// Selected classifier top passes the existing thresholds; no joint tie.
    Accepted,
    /// The selected word has no supplied classifier support.
    Unavailable,
    /// Classifier top names a different word.
    Disagreement,
    /// Insufficient probability, margin or ranking length.
    Insufficient,
    /// Joint evidence tied; deterministic ordering is not confidence.
    JointTie,
}

/// One eligible candidate; score is evidence ranking, not correctness probability.
#[derive(Clone, Debug)]
pub struct Candidate {
    word: usize,
    probability: f32,
    distance: f32,
    score: f64,
}

impl Candidate {
    /// BIP39 word index.
    pub fn word(&self) -> usize {
        self.word
    }
    /// Recorded classifier probability, without top-five renormalization.
    pub fn probability(&self) -> f32 {
        self.probability
    }
    /// CURRENT weighted edit distance, without an eligibility cutoff.
    pub fn distance(&self) -> f32 {
        self.distance
    }
    /// log10(probability) minus distance; zero gives negative infinity.
    pub fn score(&self) -> f64 {
        self.score
    }
    /// Same score function at a probability bound for saved-precision diagnostics.
    /// Panics for non-finite or out-of-range probabilities.
    pub fn score_at(&self, probability: f32) -> f64 {
        super::scoring::Config {
            rule: super::scoring::Rule::Log(1.),
            weights: CURRENT,
            length_normalized: false,
        }
        .score(probability, self.distance, 1.)
    }
    /// Recorded arithmetic for this candidate; edits are from normalized OCR.
    pub fn diagnostic(&self, raw: &str) -> serde_json::Value {
        use serde_json::json;
        let word = Word::from_index(self.word as u16).unwrap().as_str();
        json!({"word":word,"probability":self.probability,"distance":self.distance,
            "log10_probability":if self.probability>0. {json!(f64::from(self.probability).log10())} else {json!("-inf")},
            "score":if self.score.is_finite() {json!(self.score)} else {json!("-inf")},
            "edits":super::scoring::edits(&normalise(raw),word,&CURRENT)})
    }
}

/// The calibrated settings a selection is judged by.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Policy {
    /// The word model's top probability below which its verdict is uncertain.
    pub min_prob: f32,
    /// The word model's lead over its runner-up below which its verdict is uncertain.
    pub min_margin: f32,
    /// Spreads the decision score into a confidence: a word's confidence is
    /// its share of `10^(score / temperature)` over all 2048 words.
    pub temperature: f64,
    /// A pick whose confidence is below this is one to check.
    pub check_below: f64,
}

impl Policy {
    /// The word-model thresholds fixtures and the earlier stages use, with
    /// the decision settings measured in `docs/confidence-calibration.md`.
    /// Not the shipped calibration, which the model's artifact carries.
    pub const FIXED: Policy = Policy {
        min_prob: 0.85,
        min_margin: 0.75,
        temperature: 1.25,
        check_below: 0.98,
    };

    pub(crate) fn valid(&self) -> bool {
        [self.min_prob, self.min_margin]
            .iter()
            .all(|p| p.is_finite() && (0.0..=1.0).contains(p))
            && self.temperature.is_finite()
            && self.temperature > 0.0
            && self.check_below.is_finite()
            && (0.0..=1.0).contains(&self.check_below)
    }
}

/// Alternatives a selection keeps beside its pick.
pub const ALTERNATIVES: usize = 8;

/// A word and its support bound together, with no independently mutable verdict.
#[derive(Clone, Debug)]
pub struct Selection {
    policy: &'static str,
    supplied_rank_count: usize,
    word: usize,
    branch: Branch,
    text: Option<String>,
    text_source: TextSource,
    support: Support,
    top: Option<(usize, f32)>,
    margin: Option<f32>,
    thresholds: (f32, f32),
    candidates: Vec<Candidate>,
    confirmation: Confirmation,
    confidence: f64,
    check: bool,
    alternatives: Vec<(usize, f64)>,
}

impl Selection {
    /// Versioned policy identifier, distinct from the historical incumbent rule.
    pub fn policy(&self) -> &'static str {
        self.policy
    }
    /// Selected BIP39 index.
    pub fn word(&self) -> usize {
        self.word
    }
    /// Evidence path that selected the word.
    pub fn branch(&self) -> Branch {
        self.branch
    }
    /// Actual effective text used; literal OCR remains independently owned.
    pub fn text(&self) -> Option<&str> {
        self.text.as_deref()
    }
    /// Whether effective text came from a literal, matching evidence, or neither.
    pub fn text_source(&self) -> TextSource {
        self.text_source
    }
    /// Known or unavailable evidence for the selected word.
    pub fn support(&self) -> Support {
        self.support
    }
    /// Classifier top, kept distinct from the selected identity.
    pub fn classifier_top(&self) -> Option<(usize, f32)> {
        self.top
    }
    /// Classifier top-minus-runner-up margin, absent without two ranks.
    pub fn classifier_margin(&self) -> Option<f32> {
        self.margin
    }
    /// Unchanged supplied (minimum probability, minimum margin) thresholds.
    pub fn thresholds(&self) -> (f32, f32) {
        self.thresholds
    }
    /// All supplied candidates in descending joint order, empty for exact/no-text paths.
    pub fn candidates(&self) -> &[Candidate] {
        &self.candidates
    }
    /// Winner-to-runner-up score gap, absent without a joint comparison.
    pub fn score_gap(&self) -> Option<f64> {
        match self.candidates.as_slice() {
            [a, b, ..] => Some(a.score - b.score),
            _ => None,
        }
    }
    /// Why this selected word is confirmed or needs review.
    pub fn confirmation(&self) -> Confirmation {
        self.confirmation
    }
    /// The chance the pick is right: its share of `10^(score / T)` over all
    /// 2048 words, scored against the effective text even where an exact
    /// read was taken without comparing scores.
    pub fn confidence(&self) -> f64 {
        self.confidence
    }
    /// Whether a person should confirm the pick: its confidence is below the
    /// policy's `check_below`.
    pub fn check(&self) -> bool {
        self.check
    }
    /// Other words, likeliest first by decision score, each with its
    /// confidence on the same scale; never the pick itself.
    pub fn alternatives(&self) -> &[(usize, f64)] {
        &self.alternatives
    }
    /// Read-only projection of this selection's confirmation evidence.
    pub fn verdict(&self) -> Verdict {
        if self.confirmation == Confirmation::Accepted {
            Verdict::Accept
        } else {
            Verdict::Uncertain
        }
    }
    /// Plausible word eligibility; uncertainty alone does not discard exact OCR.
    /// Region, label and other explicit exclusions must still be applied by callers.
    pub fn word_like(&self) -> bool {
        self.word_like_traced(false).0
    }

    /// Evaluate the existing short circuit once, optionally retaining its operands.
    pub(crate) fn word_like_traced(&self, trace: bool) -> (bool, Option<serde_json::Value>) {
        use serde_json::json;
        let proximity = self
            .text
            .as_deref()
            .map(|text| super::near_list_evidence(text, &CURRENT));
        let near = proximity.as_ref().is_some_and(|p| p.within_budget);
        let needs_confirmation = proximity.is_some() && !near;
        let confirmed = needs_confirmation.then(|| self.verdict() == Verdict::Accept);
        // A read too long to be a list word, or carrying more than one word,
        // is not one however sure the classifier is: the classifier has 2048
        // words and must answer with one of them, so its confidence on a
        // printed `Wallet name` says nothing about whether that is a word. It
        // applies only past the near-list budget — a misspelling or a split
        // read of a real word is near the list and never reaches here — and a
        // box the geometry supports is still kept by its cell.
        let shape = self.text.as_deref().map(|text| {
            let letters = super::normalise(text).chars().count();
            let tokens = text
                .split_whitespace()
                .filter(|part| part.chars().any(char::is_alphabetic))
                .count();
            json!({"letters":letters, "alpha_tokens":tokens,
                "longest_list_word":LONGEST_WORD, "possible":letters <= LONGEST_WORD && tokens <= 1})
        });
        let impossible = shape
            .as_ref()
            .is_some_and(|s| s["possible"] == json!(false));
        let kept = proximity.is_none() || near || (confirmed == Some(true) && !impossible);
        let diagnostic = trace.then(|| json!({
            "selection": self.diagnostic(), "word_like": kept, "shape": shape,
            "near_list": proximity.map(|p| json!({
                "status": "evaluated", "normalized": p.normalized,
                "witness": p.witness.map(|(word, distance)| json!({"word":word.as_str(), "distance":distance})),
                "budget": CURRENT.budget, "within_budget": p.within_budget,
                "weights": {"substitute":CURRENT.substitute, "delete":CURRENT.delete,
                    "insert":CURRENT.insert, "first":CURRENT.first},
            })).unwrap_or_else(|| json!({"status":"skipped", "reason":"no_text"})),
            "confirmation_check": match confirmed {
                Some(accepted) => json!({"status":"evaluated", "accepted":accepted}),
                None => json!({"status":"skipped", "reason":if near {"near_list_sufficient"} else {"no_text"}}),
            },
        }));
        (kept, diagnostic)
    }

    /// Native diagnostic evidence. Joint scores are not correctness probabilities;
    /// unavailable support and non-finite score gaps have explicit representations.
    pub fn diagnostic(&self) -> serde_json::Value {
        use serde_json::json;
        let support = match self.support {
            Support::Ranked { rank, probability } => {
                json!({"kind":"ranked", "rank":rank, "probability":probability})
            }
            Support::Unavailable {
                supplied_rank_count,
            } => {
                json!({"kind":"unavailable", "supplied_rank_count":supplied_rank_count, "probability":null})
            }
        };
        let mut shown: Vec<_> = self.candidates.iter().take(8).collect();
        if let Some(top) = self.top {
            if let Some(c) = self.candidates.iter().find(|c| c.word == top.0) {
                if !shown.iter().any(|x| x.word == c.word) {
                    shown.push(c);
                }
            }
        }
        json!({"policy":self.policy(), "word":Word::from_index(self.word as u16).unwrap().as_str(),
            "branch":format!("{:?}",self.branch), "support":support,
            "confirmation":format!("{:?}",self.confirmation),
            "effective_text":self.text, "text_source":format!("{:?}",self.text_source),
            "thresholds":self.thresholds, "classifier_margin":self.margin,
            "score_gap":self.score_gap().map(|gap| if gap.is_finite() { json!(gap) } else { json!(gap.to_string()) }),
            "scoring":{"formula":"log10(p) - weighted_edit_distance", "score_is_probability":false,
                "candidate_count":self.candidates.len(),"supplied_rank_count":match self.support {Support::Unavailable{supplied_rank_count}=>supplied_rank_count,_=>self.supplied_rank_count},
                "scope":if self.policy=="bounded-log10-v1" {"legacy top-five plus budget"} else {"all supplied words; no rank or distance cutoff"},
                "weights":{"substitute":CURRENT.substitute,"delete":CURRENT.delete,"insert":CURRENT.insert,"first":CURRENT.first},
                "scored_candidates":shown.iter().map(|c|c.diagnostic(self.text.as_deref().unwrap_or(""))).collect::<Vec<_>>()}})
    }
}

/// Invalid evidence is not silently repaired or converted to index zero.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SelectionError {
    /// No exact word and no positive ranked candidate.
    NoCandidate,
    /// Non-finite/out-of-range probabilities, duplicates, indices or rank ordering.
    InvalidRanking,
    /// Non-finite/out-of-range confidence thresholds.
    InvalidThresholds,
}

impl std::fmt::Display for SelectionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for SelectionError {}

stage! {
    /// Select once from actual matching evidence, or the literal if none was supplied.
    /// Uses every supplied probability, without a rank limit or distance budget.
    /// Exact normalized words survive unavailable classifier support without an accept.
    pub fn select(
        literal: Option<&str>,
        matching: Option<&str>,
        ranked: &[(usize, f32)],
        policy: &Policy,
    ) -> Result<Selection, SelectionError> {
        select_inner(literal, matching, ranked, policy, false)
    }
}

/// Historical bounded-log10-v1 for saved comparisons, not product selection.
#[cfg(any(test, feature = "research"))]
pub fn select_bounded(
    literal: Option<&str>,
    matching: Option<&str>,
    ranked: &[(usize, f32)],
    policy: &Policy,
) -> Result<Selection, SelectionError> {
    select_inner(literal, matching, ranked, policy, true)
}

fn select_inner(
    literal: Option<&str>,
    matching: Option<&str>,
    ranked: &[(usize, f32)],
    policy: &Policy,
    bounded: bool,
) -> Result<Selection, SelectionError> {
    if !policy.valid() {
        return Err(SelectionError::InvalidThresholds);
    }
    let (min_prob, min_margin) = (policy.min_prob, policy.min_margin);
    let mut seen = [false; 2048];
    let mut previous = 1.0;
    for &(index, probability) in ranked {
        if index >= seen.len()
            || seen[index]
            || !probability.is_finite()
            || !(0.0..=1.0).contains(&probability)
            || probability > previous
        {
            return Err(SelectionError::InvalidRanking);
        }
        seen[index] = true;
        previous = probability;
    }
    let (text, text_source) = match (matching, literal) {
        (Some(text), _) => (Some(text.to_owned()), TextSource::Matching),
        (None, Some(text)) => (Some(text.to_owned()), TextSource::Literal),
        (None, None) => (None, TextSource::Absent),
    };
    let read = normalise(text.as_deref().unwrap_or(""));
    let top = ranked.first().copied();
    let margin = ranked.get(1).map(|r| ranked[0].1 - r.1);
    let mut candidates = Vec::new();
    let (word, branch) = if let Some(word) = Word::from_bip39(&read) {
        (usize::from(word.index()), Branch::ExactText)
    } else {
        let (top_word, _) = top
            .filter(|r| r.1 > 0.0)
            .ok_or(SelectionError::NoCandidate)?;
        if read.is_empty() {
            (top_word, Branch::ModelFallback)
        } else {
            for &(index, probability) in ranked.iter().take(if bounded { 5 } else { ranked.len() })
            {
                let word = Word::from_index(index as u16).unwrap();
                let d = distance(&read, word.as_str(), &CURRENT);
                if !bounded || index == top_word || d <= CURRENT.budget {
                    let mut candidate = Candidate {
                        word: index,
                        probability,
                        distance: d,
                        score: 0.0,
                    };
                    candidate.score = candidate.score_at(probability);
                    candidates.push(candidate);
                }
            }
            candidates.sort_by(|a, b| {
                b.score
                    .total_cmp(&a.score)
                    .then(b.probability.total_cmp(&a.probability))
                    .then(a.distance.total_cmp(&b.distance))
                    .then(a.word.cmp(&b.word))
            }); // BIP39 indices are lexical.
            (
                candidates[0].word,
                if candidates.len() > 1 {
                    Branch::Joint
                } else {
                    Branch::ModelFallback
                },
            )
        }
    };
    let support = ranked.iter().enumerate().find(|(_, r)| r.0 == word).map_or(
        Support::Unavailable {
            supplied_rank_count: ranked.len(),
        },
        |(rank, r)| Support::Ranked {
            rank: rank + 1,
            probability: r.1,
        },
    );
    let tied = candidates.len() > 1 && candidates[0].score == candidates[1].score;
    let confirmation = match support {
        Support::Unavailable { .. } => Confirmation::Unavailable,
        Support::Ranked { rank, .. } if rank != 1 => Confirmation::Disagreement,
        _ if tied => Confirmation::JointTie,
        _ if verdict(ranked, min_prob, min_margin) == Verdict::Accept => Confirmation::Accepted,
        _ => Confirmation::Insufficient,
    };
    let (confidence, alternatives) = spread(&read, ranked, word, policy.temperature);
    Ok(Selection {
        policy: if bounded {
            "bounded-log10-v1"
        } else {
            "all-vocabulary-log10-v1"
        },
        supplied_rank_count: ranked.len(),
        word,
        branch,
        text,
        text_source,
        support,
        top,
        margin,
        thresholds: (min_prob, min_margin),
        candidates,
        confirmation,
        confidence,
        check: confidence < policy.check_below,
        alternatives,
    })
}

/// The pick's share of `10^(score / temperature)` over all 2048 words, and
/// the likeliest other words with theirs. A word the ranking omits has
/// probability zero; with no letters read the score is the word model's alone.
fn spread(
    read: &str,
    ranked: &[(usize, f32)],
    pick: usize,
    temperature: f64,
) -> (f64, Vec<(usize, f64)>) {
    let mut probabilities = [0f32; 2048];
    for &(i, p) in ranked {
        probabilities[i] = p;
    }
    let scores: Vec<f64> = probabilities
        .iter()
        .enumerate()
        .map(|(i, &p)| {
            let edits = if read.is_empty() {
                0.0
            } else {
                f64::from(distance(read, Word::from_index(i as u16).unwrap().as_str(), &CURRENT))
            };
            f64::from(p).log10() - edits
        })
        .collect();
    let top = scores.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    if !top.is_finite() {
        return (0.0, Vec::new());
    }
    let k = std::f64::consts::LN_10 / temperature;
    let weights: Vec<f64> = scores.iter().map(|s| ((s - top) * k).exp()).collect();
    let total: f64 = weights.iter().sum();
    let mut others: Vec<usize> = (0..weights.len()).filter(|&i| i != pick && weights[i] > 0.0).collect();
    others.sort_by(|&a, &b| weights[b].total_cmp(&weights[a]).then(a.cmp(&b)));
    others.truncate(ALTERNATIVES);
    (
        weights[pick] / total,
        others.into_iter().map(|i| (i, weights[i] / total)).collect(),
    )
}

#[cfg(test)]
mod tests {

    #[test]
    fn confidence_is_the_picks_tempered_share_over_every_word() {
        // walk read exactly, so only it scores log10(0.6); every other word
        // is at least one edit away.
        let s = choose(Some("walk"), None, &[("walk", 0.6), ("wall", 0.4)]);
        let k = std::f64::consts::LN_10 / Policy::FIXED.temperature;
        let score = |p: f64, edits: f64| ((p.log10() - edits) * k).exp();
        let (walk, wall) = (score(0.6, 0.0), score(0.4, 1.0));
        // The probabilities pass through f32, so agreement is to f32 precision.
        assert!((s.confidence() - walk / (walk + wall)).abs() < 1e-6);
        assert_eq!(s.alternatives().len(), 1);
        assert_eq!(s.alternatives()[0].0, i("wall"));
        assert!((s.alternatives()[0].1 - wall / (walk + wall)).abs() < 1e-6);
    }

    #[test]
    fn an_exact_read_the_score_ranks_second_gets_a_lower_number_and_a_check() {
        // "ten" is read exactly, but the model puts nearly everything on
        // "tent", one edit away: the score ranks tent first.
        let overruled = choose(Some("ten"), None, &[("tent", 0.999), ("ten", 0.001)]);
        assert_eq!(overruled.word(), i("ten"));
        assert_eq!(overruled.branch(), Branch::ExactText);
        let agreed = choose(Some("ten"), None, &[("ten", 0.999), ("tent", 0.001)]);
        assert!(overruled.confidence() < agreed.confidence());
        assert!(overruled.check());
        assert!(!overruled.alternatives().iter().any(|&(w, _)| w == overruled.word()));
    }

    #[test]
    fn a_policy_outside_its_ranges_is_refused() {
        for policy in [
            Policy { temperature: 0.0, ..Policy::FIXED },
            Policy { temperature: f64::NAN, ..Policy::FIXED },
            Policy { check_below: 1.5, ..Policy::FIXED },
        ] {
            assert_eq!(
                select(None, None, &[(0, 1.0)], &policy).unwrap_err(),
                SelectionError::InvalidThresholds
            );
        }
    }

    /// The constant is the list's own longest word, not a guess about reads.
    #[test]
    fn the_list_has_no_word_longer() {
        assert_eq!(
            Word::all().map(|w| w.as_str().len()).max(),
            Some(LONGEST_WORD)
        );
    }

    use super::*;
    fn i(word: &str) -> usize {
        Word::from_bip39(word).unwrap().index() as usize
    }
    fn choose(text: Option<&str>, matching: Option<&str>, ranks: &[(&str, f32)]) -> Selection {
        select(
            text,
            matching,
            &ranks.iter().map(|r| (i(r.0), r.1)).collect::<Vec<_>>(),
            &Policy::FIXED,
        )
        .unwrap()
    }

    #[test]
    fn probability_changes_a_non_tied_distance_decision() {
        let strong = choose(Some("exf"), None, &[("exist", 0.99), ("exit", 0.005)]);
        assert_eq!(strong.word(), i("exist"));
        assert_eq!(strong.verdict(), Verdict::Accept);
        let weak = choose(Some("exf"), None, &[("exist", 0.6), ("exit", 0.4)]);
        assert_eq!(weak.word(), i("exit"));
        assert_eq!(weak.confirmation(), Confirmation::Disagreement);
    }

    #[test]
    fn exact_unknown_known_zero_and_known_tail_are_distinct_unconfirmed_support() {
        let missing = choose(Some("story"), None, &[("history", 0.99), ("stove", 0.001)]);
        assert_eq!(
            missing.support(),
            Support::Unavailable {
                supplied_rank_count: 2
            }
        );
        assert_eq!(missing.word(), i("story"));
        assert!(missing.word_like());
        assert_eq!(missing.verdict(), Verdict::Uncertain);
        for p in [0.0, 0.001] {
            let known = choose(Some("story"), None, &[("history", 0.99), ("story", p)]);
            assert_eq!(
                known.support(),
                Support::Ranked {
                    rank: 2,
                    probability: p
                }
            );
            assert_eq!(known.verdict(), Verdict::Uncertain);
        }
        assert_eq!(
            choose(
                Some("unlock"),
                None,
                &[("unlock", 0.999), ("unfold", 0.001)]
            )
            .verdict(),
            Verdict::Accept
        );
    }

    #[test]
    fn matching_is_selected_atomically_including_an_empty_matching_string() {
        let s = choose(
            Some("s.agree"),
            Some("agree"),
            &[("disagree", 0.99), ("degree", 0.001)],
        );
        assert_eq!(
            (s.word(), s.text_source(), s.verdict()),
            (i("agree"), TextSource::Matching, Verdict::Uncertain)
        );
        assert_eq!(s.text(), Some("agree"));
        let empty = choose(
            Some("story"),
            Some(""),
            &[("history", 0.99), ("story", 0.001)],
        );
        assert_eq!(empty.word(), i("history"));
        assert_eq!(empty.text(), Some(""));
    }

    #[test]
    fn no_candidate_is_an_error_but_exact_text_needs_no_ranking() {
        assert_eq!(
            select(None, None, &[], &crate::hybrid::Policy::FIXED).unwrap_err(),
            SelectionError::NoCandidate
        );
        assert_eq!(
            select(Some("exf"), None, &[(i("exist"), 0.0)], &crate::hybrid::Policy::FIXED).unwrap_err(),
            SelectionError::NoCandidate
        );
        assert_eq!(choose(Some("story"), None, &[]).word(), i("story"));
        assert_eq!(
            choose(None, None, &[("exist", 1.0)]).verdict(),
            Verdict::Uncertain
        );
        assert_eq!(
            choose(None, None, &[("exist", 1.0)]).text_source(),
            TextSource::Absent
        );
        assert_eq!(
            choose(Some(""), None, &[("exist", 1.0)]).text_source(),
            TextSource::Literal
        );
    }

    #[test]
    fn invalid_evidence_is_rejected_not_renormalized() {
        for ranks in [
            vec![(2048, 1.0)],
            vec![(0, f32::NAN)],
            vec![(0, f32::INFINITY)],
            vec![(0, -0.1)],
            vec![(0, 1.1)],
            vec![(0, 0.4), (1, 0.5)],
            vec![(0, 0.6), (0, 0.4)],
        ] {
            assert_eq!(
                select(Some("story"), None, &ranks, &crate::hybrid::Policy::FIXED).unwrap_err(),
                SelectionError::InvalidRanking
            );
        }
        assert_eq!(
            select(None, None, &[(0, 1.0)], &Policy { min_prob: f32::NAN, ..Policy::FIXED }).unwrap_err(),
            SelectionError::InvalidThresholds
        );
    }

    #[test]
    fn joint_ties_are_deterministic_but_not_confident() {
        let ranks = [(i("wall"), 0.5), (i("walk"), 0.5)];
        let s = select(Some("walx"), None, &ranks, &Policy { min_prob: 0.4, min_margin: 0.0, ..Policy::FIXED }).unwrap();
        assert_eq!(s.word(), i("walk"));
        assert_eq!(s.score_gap(), Some(0.0));
        assert_eq!(s.verdict(), Verdict::Uncertain);
        let s = select(
            Some("walx"),
            None,
            &[(i("walk"), 0.5), (i("wall"), 0.5)],
            &Policy { min_prob: 0.4, min_margin: 0.0, ..Policy::FIXED },
        )
        .unwrap();
        assert_eq!(s.confirmation(), Confirmation::JointTie);
    }

    /// The printed `Wallet name` on page-18 reached the word list on a
    /// classifier's confirmation, nine weighted edits from `warfare`. Length
    /// and token count are facts about the read, owing nothing to a threshold
    /// or a calibration, and they settle it before confidence is consulted.
    #[test]
    fn a_read_too_long_or_too_many_for_a_list_word_is_not_one_however_confident() {
        let confident =
            |text: &str| choose(Some(text), None, &[("welcome", 0.99), ("exit", 0.001)]);
        assert!(!confident("walletname").word_like());
        assert!(!confident("Wallet name").word_like());
        assert!(!confident("Derivation Path").word_like());
        // Eight letters is a length the list holds, so length says nothing and
        // the existing confirmation rule decides as it did before.
        assert!(confident("welcomes").word_like());
        // A near read is never asked: a misspelling or a split read of a real
        // word is within the budget and keeps its place whatever its length.
        assert!(choose(Some("welcomee"), None, &[("welcome", 0.99)]).word_like());
    }

    #[test]
    fn all_words_compete_without_budget_and_zero_probability_has_no_floor() {
        let s = choose(
            Some("zzzzzzzzzzzzzz"),
            None,
            &[("exist", 0.99), ("exit", 0.005)],
        );
        assert_eq!(s.word(), i("exist"));
        assert_eq!(s.branch(), Branch::Joint);
        // Every word still competes for the pick, and the pick is still made.
        // What the fourteen characters cost is the claim that this is a word
        // at all: no list word is that long, and the classifier's 0.99 is an
        // answer it had to give from 2048 words, not evidence about the shape.
        assert!(!s.word_like());
        let s = choose(Some("exf"), None, &[("exist", 0.99), ("exit", 0.0)]);
        assert_eq!(s.candidates()[1].score(), f64::NEG_INFINITY);
        let s = choose(
            Some("walx"),
            None,
            &[
                ("exist", 0.2),
                ("exit", 0.19),
                ("injury", 0.18),
                ("story", 0.17),
                ("history", 0.16),
                ("walk", 0.1),
            ],
        );
        assert!(s.candidates().iter().any(|c| c.word() == i("walk")));
        assert_eq!(s.word(), i("walk"));
        assert_eq!(s.confirmation(), Confirmation::Disagreement);
        assert_eq!(s.candidates().len(), 6);
    }

    #[test]
    fn all_2048_candidates_and_legacy_control_are_explicit() {
        let mut ranks: Vec<_> = (0..2048).map(|i| (i, 0.00001)).collect();
        ranks.retain(|r| r.0 != i("walk") && r.0 != i("exist"));
        ranks.insert(0, (i("walk"), 0.1));
        ranks.insert(0, (i("exist"), 0.8));
        let s = select(Some("walx"), None, &ranks, &crate::hybrid::Policy::FIXED).unwrap();
        assert_eq!(s.candidates().len(), 2048);
        assert_eq!(s.word(), i("walk"));
        assert_eq!(s.diagnostic()["scoring"]["candidate_count"], 2048);
        let far = select(Some("zzzzzzzzzzzzzz"), None, &ranks, &crate::hybrid::Policy::FIXED).unwrap();
        assert!(
            far.candidates()
                .iter()
                .all(|c| c.distance() > CURRENT.budget)
        );
        assert_eq!(far.candidates().len(), 2048);
        let legacy = select_bounded(Some("zzzzzzzzzzzzzz"), None, &ranks, &crate::hybrid::Policy::FIXED).unwrap();
        assert_eq!(legacy.candidates().len(), 1);
        assert_eq!(legacy.policy(), "bounded-log10-v1");
    }
}
