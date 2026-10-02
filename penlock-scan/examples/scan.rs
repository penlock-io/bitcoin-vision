//! Usage: cargo run --release -p penlock-scan --features bundled-models,print --example scan -- [photo.jpg]
//!
//! With a photograph, reads every Penlock strip in it and prints what each
//! cell says. Without one, splits the phrase below into three shares, draws
//! shares 1 and 3 on worksheet strips, reads both strips back and recovers
//! the phrase from the two readings: the whole round trip, nothing private
//! needed.
use bitcoin_vision_forms::Font;
use penlock::backup::{ShareCount, recover, split};
use penlock::share::{Share, ShareIndex};
use penlock::word::{Word, symbols_from_str};
use penlock_scan::sheet::{Fill, StripKind, cut_strip, front_png};
use penlock_scan::{Document, ScanOptions, Scanner};
use rand::SeedableRng;

/// The BIP39 test vector every wallet library carries: no one's backup.
const PHRASE: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const DPI: f64 = 300.0;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let scanner = Scanner::bundled()?;
    match std::env::args().nth(1) {
        Some(path) => {
            let read = scanner.scan_all(&std::fs::read(path)?, ScanOptions::default())?;
            print_document(&read.document());
        }
        None => {
            let recovered = round_trip(&scanner)?;
            println!("recovered from shares 1 and 3: {recovered}");
        }
    }
    Ok(())
}

fn print_document(document: &Document) {
    for strip in &document.observations {
        let which = match strip.share {
            Some(n) => format!("share {n}"),
            None => strip.kind.to_owned(),
        };
        println!("{which}, mean confidence {:.3}", strip.confidence);
        for (n, row) in strip.text.iter().enumerate() {
            println!("  {:>2}  {row}", n + 1);
        }
    }
}

/// Splits [`PHRASE`], draws two of its shares, reads the drawings, and
/// recovers the phrase from what was read.
fn round_trip(scanner: &Scanner) -> Result<String, Box<dyn std::error::Error>> {
    let words = Word::parse_phrase(PHRASE)?;
    // Seeded so the demo draws the same strips every run; a real split
    // takes its randomness from the operating system.
    let mut rng = rand::rngs::StdRng::seed_from_u64(0);
    let shares = split(&words, ShareCount::new(3).expect("three"), &mut rng);
    let mut read = Vec::new();
    for index in [ShareIndex::ONE, ShareIndex::THREE] {
        let share = shares
            .iter()
            .find(|s| s.index() == index)
            .expect("split made it");
        let fill = Fill::new(None, &[share], Font::PatrickHand)?;
        let page = front_png(Some(&fill), DPI)?;
        let strip = cut_strip(&page, DPI, StripKind::Share(index).slot());
        let document = scanner.scan_rgb(&strip, ScanOptions::default())?.document();
        print_document(&document);
        let [observation] = document.observations.as_slice() else {
            return Err(format!(
                "share {index}: {} strips found",
                document.observations.len()
            )
            .into());
        };
        let rows = observation
            .text
            .iter()
            .map(|row| {
                symbols_from_str(row).ok_or_else(|| format!("share {index}: unread cells in {row}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        read.push(Share::new(index, rows));
    }
    Ok(recover(&read[0], &read[1])?.phrase())
}

#[test]
fn the_demo_recovers_the_phrase_it_split() {
    assert_eq!(round_trip(&Scanner::bundled().unwrap()).unwrap(), PHRASE);
}
