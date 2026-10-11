//! Render the blank registered Penlock worksheet as a two-page A4 PDF.
//! Usage: cargo run -p penlock-scan --features print --example print_sheet -- OUTPUT.pdf

use std::{env, fs, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("penlock-registered-worksheet.pdf"));
    fs::write(&path, penlock_scan::sheet::sheet_pdf()?)?;
    eprintln!("Wrote {}", path.display());
    Ok(())
}
