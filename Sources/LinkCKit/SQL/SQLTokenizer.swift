import Foundation

struct SQLToken: Equatable {
    enum Kind { case word, quotedName, string, number, symbol }
    var kind: Kind
    var text: String
    var value: String
    var line: Int
    var keyword: String? { kind == .word ? value.uppercased() : nil }
}

struct SQLTokenizer {
    let chars: [Character]
    var index = 0
    var line = 1

    init(_ sql: String) { chars = Array(sql) }

    mutating func tokenize() throws -> [SQLToken] {
        var result: [SQLToken] = []
        while index < chars.count {
            let c = chars[index]
            if c.isWhitespace { advance(); continue }
            if c == "-", peek(1) == "-" { while index < chars.count, chars[index] != "\n" { advance() }; continue }
            if c == "/", peek(1) == "*" { try comment(); continue }
            let startLine = line
            if c == "\"" { result.append(try quotedName(line: startLine)); continue }
            if c == "'" || ((c == "E" || c == "e") && peek(1) == "'") { result.append(try string(line: startLine, escaped: c != "'")); continue }
            if c == "$", let delimiter = dollarDelimiter() { result.append(try dollar(line: startLine, delimiter: delimiter)); continue }
            if c.isLetter || c == "_" { result.append(scan(kind: .word, line: startLine) { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }); continue }
            if c.isNumber { result.append(number(line: startLine)); continue }
            if c == ":", peek(1) == ":" { index += 2; result.append(.init(kind: .symbol, text: "::", value: "::", line: startLine)); continue }
            if "(),;.[]".contains(c) { index += 1; result.append(.init(kind: .symbol, text: String(c), value: String(c), line: startLine)); continue }
            if "+-*/<>=~!@#%^&|`?".contains(c) {
                result.append(scan(kind: .symbol, line: startLine) { "+-*/<>=~!@#%^&|`?".contains($0) }); continue
            }
            index += 1
            result.append(.init(kind: .symbol, text: String(c), value: String(c), line: startLine))
        }
        return result
    }

    private mutating func advance() { if chars[index] == "\n" { line += 1 }; index += 1 }
    private func peek(_ distance: Int) -> Character? { index + distance < chars.count ? chars[index + distance] : nil }
    private mutating func scan(kind: SQLToken.Kind, line: Int, while keep: (Character) -> Bool) -> SQLToken {
        let start = index
        while index < chars.count, keep(chars[index]) { index += 1 }
        let text = String(chars[start..<index]); return .init(kind: kind, text: text, value: text, line: line)
    }
    private mutating func quotedName(line startLine: Int) throws -> SQLToken {
        let start = index; index += 1; var value = ""
        while index < chars.count {
            if chars[index] == "\"" {
                if peek(1) == "\"" { value.append("\""); index += 2; continue }
                index += 1; return .init(kind: .quotedName, text: String(chars[start..<index]), value: value, line: startLine)
            }
            value.append(chars[index]); advance()
        }
        throw LinkCError.parse("line \(startLine): a quoted name never ends")
    }
    private mutating func string(line startLine: Int, escaped: Bool) throws -> SQLToken {
        let start = index; if escaped { index += 1 }; index += 1
        while index < chars.count {
            if escaped, chars[index] == "\\" { index += min(2, chars.count - index); continue }
            if chars[index] == "'" {
                if peek(1) == "'" { index += 2; continue }
                index += 1; let text = String(chars[start..<index]); return .init(kind: .string, text: text, value: text, line: startLine)
            }
            advance()
        }
        throw LinkCError.parse("line \(startLine): a quoted string never ends")
    }
    private func dollarDelimiter() -> String? {
        var j = index + 1
        if j < chars.count, chars[j] == "$" { return "$$" }
        guard j < chars.count, chars[j].isLetter || chars[j] == "_" else { return nil }
        j += 1; while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
        guard j < chars.count, chars[j] == "$" else { return nil }
        return String(chars[index...j])
    }
    private mutating func dollar(line startLine: Int, delimiter: String) throws -> SQLToken {
        let start = index; index += delimiter.count
        while index + delimiter.count <= chars.count {
            if String(chars[index..<index + delimiter.count]) == delimiter {
                index += delimiter.count; let text = String(chars[start..<index]); return .init(kind: .string, text: text, value: text, line: startLine)
            }
            advance()
        }
        throw LinkCError.parse("line \(startLine): a quoted string never ends")
    }
    private mutating func number(line startLine: Int) -> SQLToken {
        let start = index; while index < chars.count, chars[index].isNumber { index += 1 }
        if index < chars.count, chars[index] == ".", peek(1)?.isNumber == true { index += 1; while index < chars.count, chars[index].isNumber { index += 1 } }
        if index < chars.count, chars[index] == "e" || chars[index] == "E" {
            let save = index; index += 1; if index < chars.count, chars[index] == "+" || chars[index] == "-" { index += 1 }
            let digits = index; while index < chars.count, chars[index].isNumber { index += 1 }; if digits == index { index = save }
        }
        let text = String(chars[start..<index]); return .init(kind: .number, text: text, value: text, line: startLine)
    }
    private mutating func comment() throws {
        let startLine = line; index += 2; var depth = 1
        while index < chars.count {
            if chars[index] == "/", peek(1) == "*" { depth += 1; index += 2 }
            else if chars[index] == "*", peek(1) == "/" { depth -= 1; index += 2; if depth == 0 { return } }
            else { advance() }
        }
        throw LinkCError.parse("line \(startLine): a comment never ends")
    }
}
