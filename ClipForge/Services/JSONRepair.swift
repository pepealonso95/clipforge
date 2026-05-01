import Foundation

/// Best-effort cleanup of common AI-output JSON mistakes.
/// Does NOT fix hallucinated tokens (e.g. `1ividade49.32`) — those need an AI retry.
enum JSONRepair {
    static func repair(_ s: String) -> String {
        var out = s

        // Smart / curly quotes → ASCII
        let quoteSubstitutions: [(String, String)] = [
            ("\u{201C}", "\""), // “
            ("\u{201D}", "\""), // ”
            ("\u{201E}", "\""), // „
            ("\u{2033}", "\""), // ″
            ("\u{2018}", "'"),  // ‘
            ("\u{2019}", "'"),  // ’
            ("\u{2032}", "'"),  // ′
        ]
        for (a, b) in quoteSubstitutions {
            out = out.replacingOccurrences(of: a, with: b)
        }

        // Full-width punctuation (CJK forms) → ASCII
        let widthSubstitutions: [(String, String)] = [
            ("\u{FF1A}", ":"),  // ：
            ("\u{FF0C}", ","),  // ，
            ("\u{FF1B}", ";"),  // ；
            ("\u{FF08}", "("),  // （
            ("\u{FF09}", ")"),  // ）
            ("\u{FF5B}", "{"),  // ｛
            ("\u{FF5D}", "}"),  // ｝
            ("\u{FF3B}", "["),  // ［
            ("\u{FF3D}", "]"),  // ］
            ("\u{FF02}", "\""), // ＂
            ("\u{FF07}", "'"),  // ＇
            ("\u{FF0E}", "."),  // ．
            ("\u{FF0F}", "/"),  // ／
            ("\u{FF1F}", "?"),  // ？
            ("\u{FF01}", "!"),  // ！
            ("\u{FF0D}", "-"),  // －
        ]
        for (a, b) in widthSubstitutions {
            out = out.replacingOccurrences(of: a, with: b)
        }

        // BOM
        out = out.replacingOccurrences(of: "\u{FEFF}", with: "")

        // En/em dashes inside strings break parsing very rarely — leave them alone.

        // Strip trailing commas before } or ]
        if let regex = try? NSRegularExpression(pattern: ",(\\s*[\\]}])", options: []) {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "$1")
        }

        return out
    }
}
