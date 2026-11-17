import Foundation

/// CSV field escaping shared by every exporter.
///
/// Two threats, one helper:
/// 1. **Delimiter breakage** — a comma, quote or newline inside a process name,
///    Wi-Fi SSID or skill name would otherwise shift columns.
/// 2. **Formula injection** — a field starting with `=`, `+`, `-` or `@` is
///    executed by Excel / Numbers / Sheets on open. App names come from the
///    kernel, but SSIDs and skill directory names are user-controlled, so this
///    is a real path.
///
/// Fields are always double-quoted, which makes the output valid CSV regardless
/// of embedded delimiters.
enum CSVField {
    /// Characters Excel-family apps treat as formula prefixes.
    private static let formulaPrefixes: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// Escapes one field. Never pass an already-escaped value.
    static func escape(_ raw: String) -> String {
        var value = raw
        // A pure number keeps its sign: `-12.5` must stay a number, not text.
        if let first = value.first,
           formulaPrefixes.contains(first),
           !value.isNumericField {
            value = "'" + value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Joins already-raw fields into one escaped line (no trailing newline).
    static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }
}

private extension String {
    /// `-12.5`, `+3`, `1e-4` … — a numeric string is safe without a prefix.
    var isNumericField: Bool {
        guard !isEmpty else { return false }
        return Double(self) != nil
    }
}
