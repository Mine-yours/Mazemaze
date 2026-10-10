import Foundation

/// Small helpers that reproduce the Python string semantics the server-side logic (backend/selector.py,
/// spans.py, display.py) relies on, so the on-device port behaves identically. All offsets are Unicode
/// scalar (code point) indices, like Python's, never UTF-16 or Character indices.
enum PyText {
    /// `str.isspace()` for one character (Unicode White_Space plus the C0 separators Python counts).
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    static func category(_ s: Unicode.Scalar) -> Unicode.GeneralCategory { s.properties.generalCategory }

    /// `str.isalpha()`: a letter (L*).
    static func isAlpha(_ s: Unicode.Scalar) -> Bool {
        switch category(s) {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// `str.isalnum()`: a letter or a numeric character.
    static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        if isAlpha(s) { return true }
        switch category(s) {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return s.properties.numericType != nil
        }
    }

    /// `str.isupper()` for a single character.
    static func isUpper(_ s: Unicode.Scalar) -> Bool { s.properties.isUppercase && category(s) != .titlecaseLetter }

    static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch category(s) {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// `unicodedata.combining(ch) != 0`.
    static func isCombining(_ s: Unicode.Scalar) -> Bool { s.properties.canonicalCombiningClass.rawValue != 0 }

    /// `str.strip()`.
    static func strip(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var a = 0, b = scalars.count
        while a < b, isSpace(scalars[a]) { a += 1 }
        while b > a, isSpace(scalars[b - 1]) { b -= 1 }
        return Array(scalars[a..<b])
    }

    static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var v = String.UnicodeScalarView(); v.append(contentsOf: scalars); return String(v)
    }
    static func string(_ scalars: [Unicode.Scalar]) -> String {
        var v = String.UnicodeScalarView(); v.append(contentsOf: scalars); return String(v)
    }

    static func set(_ s: String) -> Set<UInt32> { Set(s.unicodeScalars.map { $0.value }) }
}
