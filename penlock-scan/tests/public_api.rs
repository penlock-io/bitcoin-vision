//! Consumer-facing type check without the research or printing surface.

#[cfg(feature = "onnx")]
#[test]
fn both_single_and_multi_strip_scans_use_the_retained_contract() {
    use penlock_scan::scan::{Outcome, ScanState};
    use penlock_scan::{ModelBytes, ScanOptions, Scanner, Strips};

    let _: fn(ModelBytes<'_>) -> Result<Scanner, penlock_scan::ScanError> = Scanner::new;
    let _: fn(&Scanner, &[u8], ScanOptions) -> Result<penlock_scan::ScanResult, _> = Scanner::scan;
    let _: fn(&Scanner, &[u8], ScanOptions) -> Result<penlock_scan::ScanResult, _> =
        Scanner::scan_all;
    fn streamed(scanner: &Scanner) {
        let photo = image::RgbImage::new(1, 1);
        let (scan, state) = scanner.start(photo.clone(), ScanOptions::default());
        let _: ScanState<Strips> = state;
        let _: Outcome<Strips> = scan.run();
        let (scan, state) = scanner.start_all(photo, ScanOptions::default());
        let _: ScanState<Strips> = state;
        let _: Outcome<Strips> = scan.run();
    }
    let _: fn(&Scanner) = streamed;
}
