import Foundation

struct SQLSchemaParser {
    let sql: String
    private struct Pending { var table: String; var column: String; var target: String; var line: Int }
    private var tables: [SQLSchema.Table] = []
    private var skipped: [SQLSchema.Note] = []
    private var notModelled: [SQLSchema.Note] = []
    private var pending: [Pending] = []

    init(sql: String) { self.sql = sql }

    mutating func parse() throws -> SQLSchema.Parsed {
        var tokenizer = SQLTokenizer(sql)
        let tokens = try tokenizer.tokenize()
        var statements: [[SQLToken]] = [], current: [SQLToken] = []
        for token in tokens {
            if token.text == ";" { if !current.isEmpty { statements.append(current); current = [] } }
            else { current.append(token) }
        }
        if !current.isEmpty { statements.append(current) }
        for statement in statements { try parseStatement(statement) }
        for item in pending {
            if let target = tables.first(where: { $0.name == item.target }), target.columns.filter(\.pk).count == 1,
               let key = target.columns.first(where: \.pk) {
                setReference(table: item.table, column: item.column, reference: .init(table: item.target, column: key.name))
            } else {
                notModelled.append(.init(line: item.line, text: "REFERENCES \(item.target) on \(item.table).\(item.column) names no column, and \(item.target) has no single primary key here"))
            }
        }
        return .init(tables: tables, skipped: skipped, notModelled: notModelled)
    }

    private mutating func parseStatement(_ tokens: [SQLToken]) throws {
        var cursor = Cursor(tokens)
        if cursor.take("CREATE") {
            if cursor.take("OR") { _ = cursor.take("REPLACE") }
            let unlogged = cursor.take("UNLOGGED")
            if cursor.take("TABLE") { try create(&cursor, line: tokens[0].line); return }
            _ = unlogged
            skipped.append(.init(line: tokens[0].line, text: skippedText(tokens))); return
        }
        if cursor.take("ALTER"), cursor.take("TABLE") { try alter(&cursor, statementLine: tokens[0].line); return }
        skipped.append(.init(line: tokens[0].line, text: skippedText(tokens)))
    }

    private mutating func create(_ c: inout Cursor, line: Int) throws {
        if c.take("IF") { _ = c.take("NOT"); _ = c.take("EXISTS") }
        guard let name = c.name() else { skipped.append(.init(line: line, text: "CREATE TABLE")); return }
        guard c.takeSymbol("(") else { skipped.append(.init(line: line, text: "CREATE TABLE")); return }
        if tables.contains(where: { $0.name == name }) { throw LinkCError.parse("line \(line): table \(name) is created twice") }
        guard let close = matchingClose(c.tokens, from: c.index - 1) else { throw LinkCError.parse("line \(line): table \(name)'s column list never closes") }
        let body = Array(c.tokens[c.index..<close])
        tables.append(.init(name: name, columns: []))
        for element in try split(body, table: name) { try tableElement(element, table: name) }
    }

    private mutating func alter(_ c: inout Cursor, statementLine: Int) throws {
        _ = c.take("ONLY")
        if c.take("IF") { _ = c.take("EXISTS") }
        guard let table = c.name() else { skipped.append(.init(line: statementLine, text: "ALTER TABLE")); return }
        guard tables.contains(where: { $0.name == table }) else { skipped.append(.init(line: statementLine, text: "ALTER TABLE \(table)")); return }
        let actions = splitTop(Array(c.tokens[c.index...]))
        for action in actions where !action.isEmpty { try alterAction(action, table: table) }
    }

    private mutating func alterAction(_ tokens: [SQLToken], table: String) throws {
        var c = Cursor(tokens); let line = tokens[0].line
        if c.take("ADD") {
            if c.take("CONSTRAINT") { _ = c.columnName() }
            if let first = c.current, ["PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "EXCLUDE"].contains(first.keyword ?? "") {
                try constraint(Array(c.tokens[c.index...]), table: table); return
            }
            _ = c.take("COLUMN")
            var ifNot = false
            if c.take("IF") { _ = c.take("NOT"); _ = c.take("EXISTS"); ifNot = true }
            guard let name = c.columnName() else {
                skipped.append(.init(line: line, text: "ALTER TABLE \(table) ADD"))
                return
            }
            if column(table, name) != nil {
                if ifNot { return }
                throw LinkCError.parse("line \(line): table \(table) already has column \(name)")
            }
            try parseColumn(name: name, remaining: Array(c.tokens[c.index...]), table: table, line: line, append: true)
            return
        }
        if c.take("ALTER") {
            _ = c.take("COLUMN")
            guard let name = c.columnName() else {
                skipped.append(.init(line: line, text: "ALTER TABLE \(table) ALTER"))
                return
            }
            try requireColumn(table, name, line)
            if c.matches("SET", "DEFAULT") {
                _ = c.take("SET")
                _ = c.take("DEFAULT")
                let expression = render(Array(c.tokens[c.index...]))
                update(table, name) { $0.defaultValue = expression == "null" ? nil : expression }
                return
            }
            if c.matches("DROP", "DEFAULT") { update(table, name) { $0.defaultValue = nil }; return }
            if c.matches("SET", "NOT", "NULL") { update(table, name) { $0.nullable = false }; return }
            if c.matches("DROP", "NOT", "NULL") { update(table, name) { if !$0.pk { $0.nullable = true } }; return }
        }
        skipped.append(.init(line: line, text: "ALTER TABLE \(table) \(tokens.first?.keyword ?? tokens.first!.text.uppercased())"))
    }

    private mutating func tableElement(_ tokens: [SQLToken], table: String) throws {
        guard !tokens.isEmpty else { return }
        var c = Cursor(tokens); if c.take("CONSTRAINT") { _ = c.columnName() }
        if let key = c.current?.keyword, ["PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "EXCLUDE", "LIKE"].contains(key) {
            try constraint(Array(c.tokens[c.index...]), table: table)
        } else if let name = c.columnName() {
            if column(table, name) != nil { throw LinkCError.parse("line \(tokens[0].line): table \(table) names column \(name) twice") }
            try parseColumn(name: name, remaining: Array(c.tokens[c.index...]), table: table, line: tokens[0].line, append: true)
        }
    }

    private mutating func parseColumn(name: String, remaining: [SQLToken], table: String, line: Int, append: Bool) throws {
        let keywords: Set<String> = ["CONSTRAINT", "NOT", "NULL", "PRIMARY", "UNIQUE", "DEFAULT", "REFERENCES", "CHECK", "COLLATE", "GENERATED"]
        let boundary = boundaryIndex(remaining, keywords: keywords) ?? remaining.count
        let typeTokens = Array(remaining[..<boundary]); guard !typeTokens.isEmpty else { throw LinkCError.parse("line \(line): column \(name) has no type") }
        var value = BoardColumn(name: name, type: render(typeTokens)); var c = Cursor(Array(remaining[boundary...]))
        while !c.done {
            if c.take("CONSTRAINT") { _ = c.columnName(); continue }
            if c.take("NOT") { if c.take("NULL") { value.nullable = false }; continue }
            if c.take("NULL") { if !value.pk { value.nullable = true }; continue }
            if c.take("PRIMARY") { _ = c.take("KEY"); value.pk = true; value.nullable = false; continue }
            if c.take("UNIQUE") { value.unique = true; continue }
            if c.take("DEFAULT") {
                if c.take("NULL") { value.defaultValue = nil; continue }
                let end = boundaryIndex(Array(c.tokens[c.index...]), keywords: keywords) ?? c.tokens.count - c.index
                let expression = render(Array(c.tokens[c.index..<c.index + end])); value.defaultValue = expression == "null" ? nil : expression; c.index += end; continue
            }
            if c.take("REFERENCES") { try reference(&c, table: table, column: name, line: c.previousLine, into: &value); continue }
            if c.take("CHECK") { notModelled.append(.init(line: c.previousLine, text: "CHECK on \(table).\(name)")); c.skipBalanced(); continue }
            if c.take("GENERATED") {
                notModelled.append(.init(line: c.previousLine, text: "GENERATED on \(table).\(name)"));
                let end = boundaryIndex(Array(c.tokens[c.index...]), keywords: keywords) ?? c.tokens.count - c.index; c.index += end; continue
            }
            if c.take("COLLATE") { _ = c.name(); continue }
            let unknown = c.current!
            let text = unknown.keyword ?? unknown.text.uppercased()
            notModelled.append(.init(line: unknown.line, text: "\(text) on \(table).\(name)"))
            break
        }
        if append { updateTable(table) { $0.columns.append(value) } }
    }

    private mutating func constraint(_ tokens: [SQLToken], table: String) throws {
        var c = Cursor(tokens); if c.take("CONSTRAINT") { _ = c.columnName() }
        let line = c.current?.line ?? tokens[0].line
        if c.take("PRIMARY") { _ = c.take("KEY"); let names = c.nameList(); for name in names { try requireColumn(table, name, line); update(table, name) { $0.pk = true; $0.nullable = false } }; return }
        if c.take("UNIQUE") { let names = c.nameList(); for name in names { try requireColumn(table, name, line) }; if names.count == 1 { update(table, names[0]) { $0.unique = true } } else { notModelled.append(.init(line: line, text: "UNIQUE (\(names.joined(separator: ", "))) on \(table)")) }; return }
        if c.take("FOREIGN") {
            _ = c.take("KEY"); let names = c.nameList(); for name in names { try requireColumn(table, name, line) }
            if names.count != 1 { notModelled.append(.init(line: line, text: "FOREIGN KEY (\(names.joined(separator: ", "))) on \(table)")); return }
            guard c.take("REFERENCES") else {
                throw LinkCError.parse("line \(line): table \(table) has a foreign key that names no table")
            }
            var value = column(table, names[0])!
            try reference(&c, table: table, column: names[0], line: c.previousLine, into: &value)
            update(table, names[0]) { $0.references = value.references }
            return
        }
        if let kind = c.current?.keyword, ["CHECK", "EXCLUDE", "LIKE"].contains(kind) { notModelled.append(.init(line: line, text: "\(kind) on \(table)")) }
    }

    private mutating func reference(_ c: inout Cursor, table: String, column: String, line: Int, into value: inout BoardColumn) throws {
        guard let target = c.name() else {
            throw LinkCError.parse("line \(line): table \(table) has a foreign key that names no table")
        }
        if c.peekSymbol("(") { let names = c.nameList(); if let name = names.first { value.references = .init(table: target, column: name) } }
        else { pending.append(.init(table: table, column: column, target: target, line: line)) }
        while !c.done {
            if c.take("MATCH") { c.index += min(1, c.tokens.count - c.index) }
            else if c.take("ON") { c.index += min(1, c.tokens.count - c.index); if c.take("SET") || c.take("NO") { c.index += min(1, c.tokens.count - c.index) } else { c.index += min(1, c.tokens.count - c.index) }; if c.peekSymbol("(") { _ = c.nameList() } }
            else if c.take("NOT") { _ = c.take("DEFERRABLE") }
            else if c.take("DEFERRABLE") { }
            else if c.take("INITIALLY") { c.index += min(1, c.tokens.count - c.index) }
            else { break }
        }
    }

    private func split(_ tokens: [SQLToken], table: String) throws -> [[SQLToken]] {
        var result: [[SQLToken]] = [], current: [SQLToken] = []; var depth = 0
        for token in tokens {
            if token.text == "(" || token.text == "[" { depth += 1 }; if token.text == ")" || token.text == "]" { depth -= 1 }
            if token.text == ",", depth == 0 { if current.isEmpty { throw LinkCError.parse("line \(token.line): table \(table) has an empty column entry") }; result.append(current); current = [] }
            else { current.append(token) }
        }
        if current.isEmpty, let last = tokens.last, last.text == "," { throw LinkCError.parse("line \(last.line): table \(table) has an empty column entry") }
        if !current.isEmpty { result.append(current) }; return result
    }
    private func splitTop(_ tokens: [SQLToken]) -> [[SQLToken]] { var r: [[SQLToken]]=[]; var x:[SQLToken]=[]; var d=0; for t in tokens { if t.text=="(" {d+=1}; if t.text==")" {d-=1}; if t.text==",",d==0 {r.append(x);x=[]} else{x.append(t)} }; if !x.isEmpty{r.append(x)}; return r }
    private func matchingClose(_ tokens: [SQLToken], from start: Int) -> Int? { var d=0; for i in start..<tokens.count { if tokens[i].text=="("{d+=1}; if tokens[i].text==")"{d-=1;if d==0{return i}} }; return nil }
    private func boundaryIndex(_ tokens: [SQLToken], keywords: Set<String>) -> Int? { var d=0; for (i,t) in tokens.enumerated(){if t.text=="("||t.text=="["{d+=1};if t.text==")"||t.text=="]"{d-=1};if d==0,let k=t.keyword,keywords.contains(k){return i}};return nil }
    private func render(_ tokens: [SQLToken]) -> String {
        var filtered:[SQLToken]=[]; var i=0
        while i<tokens.count { if i+1<tokens.count, tokens[i].value.lowercased()=="public", tokens[i+1].text=="." {i+=2;continue};filtered.append(tokens[i]);i+=1 }
        var out=""; var previous:SQLToken?
        for t in filtered { let value = t.kind == .word ? t.value.lowercased() : t.kind == .quotedName ? SQLSchema.quotedIfNeeded(t.value) : t.text
            let noBefore:Set<String>=[")","]",",","[","::","."]; let noAfter:Set<String>=["(","[","::","."]
            var space = previous != nil && !noBefore.contains(t.text) && !noAfter.contains(previous!.text)
            if t.text=="(", let p=previous, p.kind == .word || p.kind == .quotedName || ["]",")","(","::","."].contains(p.text) {space=false}
            if previous?.text=="," {space=true}; if space{out.append(" ")};out.append(value);previous=t }
        return out
    }
    private func skippedText(_ t:[SQLToken])->String { var words=t.filter{$0.kind == .word}.map{$0.value.uppercased()}; if words.first=="CREATE",words.dropFirst().prefix(2).elementsEqual(["OR","REPLACE"]){words.removeSubrange(1...2)};return words.prefix(2).joined(separator:" ") }
    private func column(_ table:String,_ name:String)->BoardColumn? { tables.first{$0.name==table}?.columns.first{$0.name==name} }
    private mutating func requireColumn(_ table:String,_ name:String,_ line:Int)throws {if column(table,name)==nil{throw LinkCError.parse("line \(line): table \(table) has no column \(name)")}}
    private mutating func updateTable(_ name:String,_ body:(inout SQLSchema.Table)->Void){if let i=tables.firstIndex(where:{$0.name==name}){body(&tables[i])}}
    private mutating func update(_ table:String,_ column:String,_ body:(inout BoardColumn)->Void){updateTable(table){if let i=$0.columns.firstIndex(where:{$0.name==column}){body(&$0.columns[i])}}}
    private mutating func setReference(table:String,column:String,reference:BoardColumnReference){update(table,column){$0.references=reference}}
}

private struct Cursor {
    let tokens:[SQLToken]; var index=0; var previousLine=1
    init(_ tokens:[SQLToken]){self.tokens=tokens}
    var done:Bool{index>=tokens.count}; var current:SQLToken?{done ? nil:tokens[index]}
    func peek(_ k:String)->Bool{current?.keyword==k}; func peekSymbol(_ s:String)->Bool{current?.text==s}
    func matches(_ keywords: String...) -> Bool {
        guard index + keywords.count <= tokens.count else { return false }
        return zip(tokens[index..<index + keywords.count], keywords).allSatisfy { $0.keyword == $1 }
    }
    mutating func take(_ k:String)->Bool{guard peek(k) else{return false};previousLine=tokens[index].line;index+=1;return true}
    mutating func takeSymbol(_ s:String)->Bool{guard peekSymbol(s) else{return false};previousLine=tokens[index].line;index+=1;return true}
    mutating func columnName()->String?{guard let t=current,t.kind == .word || t.kind == .quotedName else{return nil};index+=1;return t.kind == .word ? t.value.lowercased():t.value}
    mutating func name()->String?{guard let first=columnName() else{return nil};if takeSymbol("."),let second=columnName(){return first=="public" ? second:"\(first).\(second)"};return first}
    mutating func nameList()->[String]{guard takeSymbol("(") else{return []};var r:[String]=[];while !done,!takeSymbol(")"){if let n=columnName(){r.append(n)}else{index+=1};_ = takeSymbol(",")};return r}
    mutating func skipBalanced(){guard takeSymbol("(") else{return};var d=1;while !done,d>0{if takeSymbol("("){d+=1}else if takeSymbol(")"){d-=1}else{index+=1}}}
}
