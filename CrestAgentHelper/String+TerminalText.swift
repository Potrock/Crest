import Foundation

extension String {
    /// The text without control characters, so a page's title or address
    /// can't steer the terminal that shows it.
    var withoutControlCharacters: String {
        String(
            String.UnicodeScalarView(
                unicodeScalars.filter { scalar in
                    !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
                        || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value))
                }))
    }
}
