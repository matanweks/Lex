import Foundation

/// Hebrew (and Arabic) runs right to left. Text views pick a paragraph's direction from its first
/// letter, so a Hebrew paragraph that opens with an English word ("Tandem מפעיל…") comes out
/// backwards: the period at the wrong end, "ה-CLI" split apart. These read the direction from
/// the letters instead, so each paragraph can be marked with it.
public enum TextDirection {
    public static let rightToLeftMark: Character = "\u{200F}"
    public static let leftToRightMark: Character = "\u{200E}"

    public static func isRightToLeftLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
        default: return false
        }
    }

    /// At least 40% of the letters are Hebrew or Arabic. Not a majority: Hebrew writing keeps
    /// English names and terms, and those are long words.
    public static func isRightToLeft(_ text: some StringProtocol) -> Bool {
        var rightToLeft = 0, letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if isRightToLeftLetter(scalar) { rightToLeft += 1 }
        }
        return letters > 0 && Double(rightToLeft) >= Double(letters) * 0.4
    }

    /// A direction mark for the start of each paragraph that has letters, at its Character
    /// offset. None for text without Hebrew or Arabic, which already lays out right.
    public static func paragraphMarks(_ text: String) -> [(offset: Int, mark: Character)] {
        guard text.unicodeScalars.contains(where: isRightToLeftLetter) else { return [] }
        var marks: [(offset: Int, mark: Character)] = []
        var offset = 0
        for paragraph in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if paragraph.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) {
                marks.append((offset, isRightToLeft(paragraph) ? rightToLeftMark : leftToRightMark))
            }
            offset += paragraph.count + 1
        }
        return marks
    }

    /// The text with each paragraph's direction mark in front of it.
    public static func marked(_ text: String) -> String {
        var out = text
        for (offset, mark) in paragraphMarks(text).reversed() {
            out.insert(mark, at: out.index(out.startIndex, offsetBy: offset))
        }
        return out
    }
}
