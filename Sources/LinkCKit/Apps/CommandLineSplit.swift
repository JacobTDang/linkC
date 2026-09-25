import Foundation

/// Splits a command line typed in Settings into argv, the way a shell splits words: spaces and
/// tabs separate words, single and double quotes group, and a backslash escapes the next
/// character (inside double quotes too). No variable, glob or `~` expansion happens.
public enum CommandLineSplit {
    public static func split(_ line: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaping = false
        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\" && open == "\"" {
                    escaping = true
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "\\":
                escaping = true
                inWord = true
            case "'", "\"":
                quote = character
                inWord = true
            case " ", "\t":
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            default:
                current.append(character)
                inWord = true
            }
        }
        if let open = quote { throw LinkCError.parse("the command has an unclosed \(open) quote") }
        if escaping { throw LinkCError.parse("the command ends with a backslash") }
        if inWord { words.append(current) }
        return words
    }

    /// The inverse of `split`: a word with no special characters stays bare, and any other word
    /// is single-quoted (an embedded single quote becomes `'\''`).
    public static func join(_ argv: [String]) -> String {
        argv.map { word in
            let plain = !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber || "-_./:{}=@%+,".contains($0) }
            return plain ? word : "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }.joined(separator: " ")
    }
}
