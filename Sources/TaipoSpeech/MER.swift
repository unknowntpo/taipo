import Foundation

/// Mixed error rate (Spec 011 Behavior 1): one token per Han character, one per run of letters or digits.
public enum MER {
    /// Full-width ASCII to half-width, lowercased; punctuation and whitespace become token boundaries.
    public static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E: scalars.append(Unicode.Scalar(scalar.value - 0xFEE0)!)
            case 0x3000: scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        return String(scalars).lowercased()
    }

    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty { tokens.append(word); word = "" }
        }
        for scalar in normalize(text).unicodeScalars {
            if scalar.properties.isIdeographic {
                flush()
                tokens.append(String(scalar))
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                word.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    public static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Edit distance and reference token count, so corpus MER can sum errors over tokens.
    public static func errors(reference: String, hypothesis: String) -> (errors: Int, tokens: Int) {
        let ref = tokenize(reference)
        return (editDistance(ref, tokenize(hypothesis)), ref.count)
    }

    public static func rate(reference: String, hypothesis: String) -> Double {
        let (errors, tokens) = errors(reference: reference, hypothesis: hypothesis)
        return tokens == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(tokens)
    }
}
