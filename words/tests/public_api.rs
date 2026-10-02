//! Compile the intended interface from outside the scanner crate.

use bitcoin_vision_words::scan::{Outcome, ScanState};
use bitcoin_vision_words::{ModelBytes, ScanOptions, ScanResult, Scanner, Words};

#[test]
fn scan_and_saved_projections_are_the_external_contract() {
    let _: fn(ModelBytes<'_>) -> Result<Scanner, bitcoin_vision_words::ScanError> = Scanner::new;
    let _: fn(&Scanner, &[u8], ScanOptions) -> Result<ScanResult, _> = Scanner::scan;

    fn driven(scanner: &Scanner) {
        let (scan, state) = scanner.start(image::RgbImage::new(1, 1), ScanOptions::default());
        let _: ScanState<Words> = state;
        let _: Outcome<Words> = scan.run();
    }
    let _: fn(&Scanner) = driven;

    fn projections(result: &ScanResult) {
        let _ = result.document();
        let _ = result.review();
        let _ = result.selected_boxes();
        let _ = result.decision_files(1, "unknown");
    }
    let _: fn(&ScanResult) = projections;
}
