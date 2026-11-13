import Foundation

/** The one name rule shared by input validation and persistence. */
func normalizedWalletName(input: String) -> String? {
    let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.unicodeScalars.count <= 40 else { return nil }
    // Java's ISO control characters: U+0000–U+001F and U+007F–U+009F.
    let control = name.unicodeScalars.contains { $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) }
    return control ? nil : name
}
