//! The front page is cheap to fetch.

/// A README animation is easy to replace with a heavier one; fetching this
/// page should stay cheap, and a recording is only worth its bytes while the
/// page still points at it.
#[test]
fn the_demo_animations_are_referenced_and_stay_small() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let readme = std::fs::read_to_string(root.join("README.md")).unwrap();
    let mut total = 0;
    for name in ["docs/images/scan.gif", "docs/images/penlock-scan.gif"] {
        assert!(readme.contains(name), "{name} is not on the page");
        let data = std::fs::read(root.join(name)).unwrap();
        assert_eq!(&data[..6], b"GIF89a", "{name}");
        total += data.len();
    }
    assert!(total < 6 << 20, "{total} bytes of animation");
}
