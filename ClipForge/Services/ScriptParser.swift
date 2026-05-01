import Foundation

enum ScriptParser {
    /// Parse the AI's stdout into [Script]. Tolerant of:
    /// - Fenced ```json blocks
    /// - Naked JSON
    /// - Surrounding prose
    static func parseScripts(from raw: String, attemptRepair: Bool = true) throws -> [Script] {
        let extracted = try extractJSON(from: raw)
        let candidates: [String] = attemptRepair
            ? [extracted, JSONRepair.repair(extracted)]
            : [extracted]

        var lastError: Error?
        for json in candidates {
            guard let data = json.data(using: .utf8) else {
                lastError = AICliError.invalidJSON("UTF-8 conversion failed", raw: raw)
                continue
            }
            if let decoded = try? JSONDecoder().decode(ScriptResponse.self, from: data) {
                return decoded.scripts
            }
            if let arr = try? JSONDecoder().decode([Script].self, from: data) {
                return arr
            }
            // Capture the actual decode error from the first attempt for reporting.
            do {
                _ = try JSONDecoder().decode(ScriptResponse.self, from: data)
            } catch {
                lastError = error
            }
        }
        throw AICliError.invalidJSON(String(describing: lastError ?? AICliError.invalidJSON("unknown", raw: raw)), raw: raw)
    }

    /// Extract a JSON object string from arbitrary AI output.
    /// Priority: first ```json fence → first ``` fence → outermost {…}.
    static func extractJSON(from raw: String) throws -> String {
        // Try ```json fenced block.
        if let fenced = firstFencedBlock(in: raw, preferLanguage: "json") {
            return fenced
        }
        // Try any fenced block.
        if let fenced = firstFencedBlock(in: raw, preferLanguage: nil) {
            return fenced
        }
        // Try outermost {...} or [...].
        if let obj = outermostBraceSpan(in: raw) {
            return obj
        }
        throw AICliError.invalidJSON("No JSON found in response", raw: raw)
    }

    private static func firstFencedBlock(in s: String, preferLanguage: String?) -> String? {
        let pattern: String
        if let lang = preferLanguage {
            pattern = "```\\s*\(NSRegularExpression.escapedPattern(for: lang))\\s*\\n([\\s\\S]*?)\\n```"
        } else {
            pattern = "```[a-zA-Z]*\\s*\\n([\\s\\S]*?)\\n```"
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = regex.firstMatch(in: s, options: [], range: range) else { return nil }
        guard match.numberOfRanges >= 2 else { return nil }
        guard let r = Range(match.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func outermostBraceSpan(in s: String) -> String? {
        // Find first { or [ and match its closing counterpart, ignoring brackets in strings.
        let openers: [Character: Character] = ["{": "}", "[": "]"]
        guard let firstIdx = s.firstIndex(where: { openers[$0] != nil }) else { return nil }
        let opener = s[firstIdx]
        let closer = openers[opener]!

        var depth = 0
        var inString = false
        var escape = false
        var i = firstIdx
        while i < s.endIndex {
            let c = s[i]
            if escape { escape = false; i = s.index(after: i); continue }
            if inString {
                if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == opener { depth += 1 }
                else if c == closer {
                    depth -= 1
                    if depth == 0 {
                        return String(s[firstIdx...i])
                    }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
