import Foundation

/// One lexical unit of SQL, preserving its original spelling and source line.
struct SQLToken: Equatable {
    /// The lexical categories needed by the schema parser.
    enum Kind { case word, quotedName, string, number, symbol }
    var kind: Kind
    var text: String
    var value: String
    var line: Int
    var keyword: String? { kind == .word ? value.uppercased() : nil }
}

/// A deterministic scanner for the supported Postgres lexical forms.
struct SQLTokenizer {
    let chars: [Character]
    var index = 0
    var line = 1

    init(_ sql: String) { chars = Array(sql) }

    /// Scans all tokens, discarding whitespace and comments.
    mutating func tokenize() throws -> [SQLToken] {
        var result: [SQLToken] = []
        while index < chars.count {
            let character = chars[index]
            if character.isWhitespace {
                advance()
                continue
            }
            if character == "-", peek(1) == "-" {
                while index < chars.count, chars[index] != "\n" { advance() }
                continue
            }
            if character == "/", peek(1) == "*" {
                try comment()
                continue
            }
            let startLine = line
            if character == "\"" {
                result.append(try quotedName(line: startLine))
                continue
            }
            if character == "'" || ((character == "E" || character == "e") && peek(1) == "'") {
                result.append(try string(line: startLine, escaped: character != "'"))
                continue
            }
            if character == "$", let delimiter = dollarDelimiter() {
                result.append(try dollar(line: startLine, delimiter: delimiter))
                continue
            }
            if character.isASCIILetter || character == "_" {
                result.append(
                    scan(kind: .word, line: startLine) {
                        $0.isASCIILetter || $0.isASCIIDigit || $0 == "_" || $0 == "$"
                    })
                continue
            }
            if character.isASCIIDigit {
                result.append(number(line: startLine))
                continue
            }
            if character == ":", peek(1) == ":" {
                index += 2
                result.append(.init(kind: .symbol, text: "::", value: "::", line: startLine))
                continue
            }
            if "(),;.[]".contains(character) {
                index += 1
                result.append(.init(kind: .symbol, text: String(character), value: String(character), line: startLine))
                continue
            }
            if "+-*/<>=~!@#%^&|`?".contains(character) {
                result.append(scan(kind: .symbol, line: startLine) { "+-*/<>=~!@#%^&|`?".contains($0) })
                continue
            }
            index += 1
            result.append(.init(kind: .symbol, text: String(character), value: String(character), line: startLine))
        }
        return result
    }

    /// Advances one character while maintaining the one-based line number.
    private mutating func advance() {
        if chars[index] == "\n" { line += 1 }
        index += 1
    }
    /// Returns a character relative to the scanner without consuming it.
    private func peek(_ distance: Int) -> Character? {
        index + distance < chars.count ? chars[index + distance] : nil
    }
    /// Consumes a run of characters that satisfy `keep`.
    private mutating func scan(kind: SQLToken.Kind, line: Int, while keep: (Character) -> Bool)
        -> SQLToken
    {
        let start = index
        while index < chars.count, keep(chars[index]) { index += 1 }
        let text = String(chars[start..<index])
        return .init(kind: kind, text: text, value: text, line: line)
    }
    /// Scans a double-quoted identifier and unescapes doubled quotes.
    private mutating func quotedName(line startLine: Int) throws -> SQLToken {
        let start = index
        index += 1
        var value = ""
        while index < chars.count {
            if chars[index] == "\"" {
                if peek(1) == "\"" {
                    value.append("\"")
                    index += 2
                    continue
                }
                index += 1
                return .init(
                    kind: .quotedName, text: String(chars[start..<index]), value: value, line: startLine)
            }
            value.append(chars[index])
            advance()
        }
        throw LinkCError.parse("line \(startLine): a quoted name never ends")
    }
    /// Scans a standard or escape string while preserving its source text.
    private mutating func string(line startLine: Int, escaped: Bool) throws -> SQLToken {
        let start = index
        if escaped { index += 1 }
        index += 1
        while index < chars.count {
            if escaped, chars[index] == "\\" {
                index += min(2, chars.count - index)
                continue
            }
            if chars[index] == "'" {
                if peek(1) == "'" {
                    index += 2
                    continue
                }
                index += 1
                let text = String(chars[start..<index])
                return .init(kind: .string, text: text, value: text, line: startLine)
            }
            advance()
        }
        throw LinkCError.parse("line \(startLine): a quoted string never ends")
    }
    /// Recognizes a valid dollar-quote delimiter at the current position.
    private func dollarDelimiter() -> String? {
        var delimiterEnd = index + 1
        if delimiterEnd < chars.count, chars[delimiterEnd] == "$" { return "$$" }
        guard delimiterEnd < chars.count,
            chars[delimiterEnd].isASCIILetter || chars[delimiterEnd] == "_"
        else { return nil }
        delimiterEnd += 1
        while delimiterEnd < chars.count,
            chars[delimiterEnd].isASCIILetter || chars[delimiterEnd].isASCIIDigit
                || chars[delimiterEnd] == "_"
        {
            delimiterEnd += 1
        }
        guard delimiterEnd < chars.count, chars[delimiterEnd] == "$" else { return nil }
        return String(chars[index...delimiterEnd])
    }
    /// Scans through the matching closing dollar-quote delimiter.
    private mutating func dollar(line startLine: Int, delimiter: String) throws -> SQLToken {
        let start = index
        index += delimiter.count
        while index + delimiter.count <= chars.count {
            if String(chars[index..<index + delimiter.count]) == delimiter {
                index += delimiter.count
                let text = String(chars[start..<index])
                return .init(kind: .string, text: text, value: text, line: startLine)
            }
            advance()
        }
        throw LinkCError.parse("line \(startLine): a quoted string never ends")
    }
    /// Scans a decimal number with optional fraction and exponent.
    private mutating func number(line startLine: Int) -> SQLToken {
        let start = index
        while index < chars.count, chars[index].isASCIIDigit { index += 1 }
        if index < chars.count, chars[index] == ".", peek(1)?.isASCIIDigit == true {
            index += 1
            while index < chars.count, chars[index].isASCIIDigit { index += 1 }
        }
        if index < chars.count, chars[index] == "e" || chars[index] == "E" {
            let save = index
            index += 1
            if index < chars.count, chars[index] == "+" || chars[index] == "-" { index += 1 }
            let digits = index
            while index < chars.count, chars[index].isASCIIDigit { index += 1 }
            if digits == index { index = save }
        }
        let text = String(chars[start..<index])
        return .init(kind: .number, text: text, value: text, line: startLine)
    }
    /// Skips a block comment, including nested block comments.
    private mutating func comment() throws {
        let startLine = line
        index += 2
        var depth = 1
        while index < chars.count {
            if chars[index] == "/", peek(1) == "*" {
                depth += 1
                index += 2
            } else if chars[index] == "*", peek(1) == "/" {
                depth -= 1
                index += 2
                if depth == 0 { return }
            } else {
                advance()
            }
        }
        throw LinkCError.parse("line \(startLine): a comment never ends")
    }
}

/// ASCII character classes used by the SQL scanner.
extension Character {
    fileprivate var isASCIILetter: Bool { ("A"..."Z").contains(self) || ("a"..."z").contains(self) }
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
