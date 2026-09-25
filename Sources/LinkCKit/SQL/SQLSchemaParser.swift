import Foundation

/// Turns tokenized Postgres schema statements into LinkCKit table models.
struct SQLSchemaParser {
  let sql: String
  /// A reference without a named target column, resolved after all statements are read.
  private struct Pending {
    var table: String
    var column: String
    var target: String
    var line: Int
  }
  private var tables: [SQLSchema.Table] = []
  private var skipped: [SQLSchema.Note] = []
  private var notModelled: [SQLSchema.Note] = []
  private var pending: [Pending] = []

  init(sql: String) { self.sql = sql }

  /// Parses every statement and resolves references that rely on a table's sole primary key.
  mutating func parse() throws -> SQLSchema.Parsed {
    var tokenizer = SQLTokenizer(sql)
    let tokens = try tokenizer.tokenize()
    var statements: [[SQLToken]] = []
    var current: [SQLToken] = []
    for token in tokens {
      if token.text == ";" {
        if !current.isEmpty {
          statements.append(current)
          current = []
        }
      } else {
        current.append(token)
      }
    }
    if !current.isEmpty { statements.append(current) }
    for statement in statements { try parseStatement(statement) }
    for item in pending {
      if let target = tables.first(where: { $0.name == item.target }),
        target.columns.filter(\.pk).count == 1,
        let key = target.columns.first(where: \.pk)
      {
        setReference(
          table: item.table, column: item.column,
          reference: .init(table: item.target, column: key.name))
      } else {
        notModelled.append(
          .init(
            line: item.line,
            text:
              "REFERENCES \(item.target) on \(item.table).\(item.column) names no column, and \(item.target) has no single primary key here"
          ))
      }
    }
    return .init(tables: tables, skipped: skipped, notModelled: notModelled)
  }

  /// Dispatches one statement to the supported CREATE or ALTER parser.
  private mutating func parseStatement(_ tokens: [SQLToken]) throws {
    var cursor = Cursor(tokens)
    if cursor.take("CREATE") {
      if cursor.take("OR") { _ = cursor.take("REPLACE") }
      let unlogged = cursor.take("UNLOGGED")
      if cursor.take("TABLE") {
        try create(&cursor, line: tokens[0].line)
        return
      }
      _ = unlogged
      skipped.append(.init(line: tokens[0].line, text: skippedText(tokens)))
      return
    }
    if cursor.take("ALTER"), cursor.take("TABLE") {
      try alter(&cursor, statementLine: tokens[0].line)
      return
    }
    skipped.append(.init(line: tokens[0].line, text: skippedText(tokens)))
  }

  /// Reads one CREATE TABLE statement.
  private mutating func create(_ cursor: inout Cursor, line: Int) throws {
    if cursor.take("IF") {
      _ = cursor.take("NOT")
      _ = cursor.take("EXISTS")
    }
    guard let name = cursor.name() else {
      skipped.append(.init(line: line, text: "CREATE TABLE"))
      return
    }
    guard cursor.takeSymbol("(") else {
      skipped.append(.init(line: line, text: "CREATE TABLE"))
      return
    }
    if tables.contains(where: { $0.name == name }) {
      throw LinkCError.parse("line \(line): table \(name) is created twice")
    }
    guard let close = matchingClose(cursor.tokens, from: cursor.index - 1) else {
      throw LinkCError.parse("line \(line): table \(name)'s column list never closes")
    }
    let body = Array(cursor.tokens[cursor.index..<close])
    tables.append(.init(name: name, columns: []))
    for element in try split(body, table: name) { try tableElement(element, table: name) }
  }

  /// Reads one ALTER TABLE statement and applies each comma-separated action.
  private mutating func alter(_ cursor: inout Cursor, statementLine: Int) throws {
    _ = cursor.take("ONLY")
    if cursor.take("IF") { _ = cursor.take("EXISTS") }
    guard let table = cursor.name() else {
      skipped.append(.init(line: statementLine, text: "ALTER TABLE"))
      return
    }
    guard tables.contains(where: { $0.name == table }) else {
      skipped.append(.init(line: statementLine, text: "ALTER TABLE \(table)"))
      return
    }
    let actions = splitTop(Array(cursor.tokens[cursor.index...]))
    for action in actions where !action.isEmpty { try alterAction(action, table: table) }
  }

  /// Applies one supported ALTER TABLE action or records it as skipped.
  private mutating func alterAction(_ tokens: [SQLToken], table: String) throws {
    var cursor = Cursor(tokens)
    let line = tokens[0].line
    if cursor.take("ADD") {
      if cursor.take("CONSTRAINT") { _ = cursor.columnName() }
      if let first = cursor.current,
        ["PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "EXCLUDE"].contains(first.keyword ?? "")
      {
        try constraint(Array(cursor.tokens[cursor.index...]), table: table)
        return
      }
      _ = cursor.take("COLUMN")
      var ifNot = false
      if cursor.take("IF") {
        _ = cursor.take("NOT")
        _ = cursor.take("EXISTS")
        ifNot = true
      }
      guard let name = cursor.columnName() else {
        skipped.append(.init(line: line, text: "ALTER TABLE \(table) ADD"))
        return
      }
      if column(table, name) != nil {
        if ifNot { return }
        throw LinkCError.parse("line \(line): table \(table) already has column \(name)")
      }
      try parseColumn(
        name: name, remaining: Array(cursor.tokens[cursor.index...]), table: table, line: line,
        append: true)
      return
    }
    if cursor.take("ALTER") {
      _ = cursor.take("COLUMN")
      guard let name = cursor.columnName() else {
        skipped.append(.init(line: line, text: "ALTER TABLE \(table) ALTER"))
        return
      }
      try requireColumn(table, name, line)
      if cursor.matches("SET", "DEFAULT") {
        _ = cursor.take("SET")
        _ = cursor.take("DEFAULT")
        let expression = render(Array(cursor.tokens[cursor.index...]))
        update(table, name) { $0.defaultValue = expression == "null" ? nil : expression }
        return
      }
      if cursor.matches("DROP", "DEFAULT") {
        update(table, name) { $0.defaultValue = nil }
        return
      }
      if cursor.matches("SET", "NOT", "NULL") {
        update(table, name) { $0.nullable = false }
        return
      }
      if cursor.matches("DROP", "NOT", "NULL") {
        update(table, name) { if !$0.pk { $0.nullable = true } }
        return
      }
    }
    skipped.append(
      .init(
        line: line,
        text: "ALTER TABLE \(table) \(tokens.first?.keyword ?? tokens.first!.text.uppercased())"))
  }

  /// Reads a column or table constraint from a CREATE TABLE body.
  private mutating func tableElement(_ tokens: [SQLToken], table: String) throws {
    guard !tokens.isEmpty else { return }
    var c = Cursor(tokens)
    if c.take("CONSTRAINT") { _ = c.columnName() }
    if let key = c.current?.keyword,
      ["PRIMARY", "FOREIGN", "UNIQUE", "CHECK", "EXCLUDE", "LIKE"].contains(key)
    {
      try constraint(Array(c.tokens[c.index...]), table: table)
    } else if let name = c.columnName() {
      if column(table, name) != nil {
        throw LinkCError.parse("line \(tokens[0].line): table \(table) names column \(name) twice")
      }
      try parseColumn(
        name: name, remaining: Array(c.tokens[c.index...]), table: table, line: tokens[0].line,
        append: true)
    }
  }

  /// Reads a column's type and supported inline constraints.
  private mutating func parseColumn(
    name: String, remaining: [SQLToken], table: String, line: Int, append: Bool
  ) throws {
    let keywords: Set<String> = [
      "CONSTRAINT", "NOT", "NULL", "PRIMARY", "UNIQUE", "DEFAULT", "REFERENCES", "CHECK", "COLLATE",
      "GENERATED",
    ]
    let boundary = boundaryIndex(remaining, keywords: keywords) ?? remaining.count
    let typeTokens = Array(remaining[..<boundary])
    guard !typeTokens.isEmpty else {
      throw LinkCError.parse("line \(line): column \(name) has no type")
    }
    var value = BoardColumn(name: name, type: render(typeTokens))
    var c = Cursor(Array(remaining[boundary...]))
    while !c.done {
      if c.take("CONSTRAINT") {
        _ = c.columnName()
        continue
      }
      if c.take("NOT") {
        if c.take("NULL") { value.nullable = false }
        continue
      }
      if c.take("NULL") {
        if !value.pk { value.nullable = true }
        continue
      }
      if c.take("PRIMARY") {
        _ = c.take("KEY")
        value.pk = true
        value.nullable = false
        continue
      }
      if c.take("UNIQUE") {
        value.unique = true
        continue
      }
      if c.take("DEFAULT") {
        if c.take("NULL") {
          value.defaultValue = nil
          continue
        }
        let end =
          boundaryIndex(Array(c.tokens[c.index...]), keywords: keywords) ?? c.tokens.count - c.index
        let expression = render(Array(c.tokens[c.index..<c.index + end]))
        value.defaultValue = expression == "null" ? nil : expression
        c.index += end
        continue
      }
      if c.take("REFERENCES") {
        try reference(&c, table: table, column: name, line: c.previousLine, into: &value)
        continue
      }
      if c.take("CHECK") {
        notModelled.append(.init(line: c.previousLine, text: "CHECK on \(table).\(name)"))
        c.skipBalanced()
        continue
      }
      if c.take("GENERATED") {
        notModelled.append(.init(line: c.previousLine, text: "GENERATED on \(table).\(name)"))
        let end =
          boundaryIndex(Array(c.tokens[c.index...]), keywords: keywords) ?? c.tokens.count - c.index
        c.index += end
        continue
      }
      if c.take("COLLATE") {
        _ = c.name()
        continue
      }
      let unknown = c.current!
      let text = unknown.keyword ?? unknown.text.uppercased()
      notModelled.append(.init(line: unknown.line, text: "\(text) on \(table).\(name)"))
      break
    }
    if append { updateTable(table) { $0.columns.append(value) } }
  }

  /// Applies a table-level key or records an unsupported table constraint.
  private mutating func constraint(_ tokens: [SQLToken], table: String) throws {
    var c = Cursor(tokens)
    if c.take("CONSTRAINT") { _ = c.columnName() }
    let line = c.current?.line ?? tokens[0].line
    if c.take("PRIMARY") {
      _ = c.take("KEY")
      let names = c.nameList()
      for name in names {
        try requireColumn(table, name, line)
        update(table, name) {
          $0.pk = true
          $0.nullable = false
        }
      }
      return
    }
    if c.take("UNIQUE") {
      let names = c.nameList()
      for name in names { try requireColumn(table, name, line) }
      if names.count == 1 {
        update(table, names[0]) { $0.unique = true }
      } else {
        notModelled.append(
          .init(line: line, text: "UNIQUE (\(names.joined(separator: ", "))) on \(table)"))
      }
      return
    }
    if c.take("FOREIGN") {
      _ = c.take("KEY")
      let names = c.nameList()
      for name in names { try requireColumn(table, name, line) }
      if names.count != 1 {
        notModelled.append(
          .init(line: line, text: "FOREIGN KEY (\(names.joined(separator: ", "))) on \(table)"))
        return
      }
      guard c.take("REFERENCES") else {
        throw LinkCError.parse("line \(line): table \(table) has a foreign key that names no table")
      }
      var value = column(table, names[0])!
      try reference(&c, table: table, column: names[0], line: c.previousLine, into: &value)
      update(table, names[0]) { $0.references = value.references }
      return
    }
    if let kind = c.current?.keyword, ["CHECK", "EXCLUDE", "LIKE"].contains(kind) {
      notModelled.append(.init(line: line, text: "\(kind) on \(table)"))
    }
  }

  /// Reads a REFERENCES clause and consumes its referential actions.
  private mutating func reference(
    _ c: inout Cursor, table: String, column: String, line: Int, into value: inout BoardColumn
  ) throws {
    guard let target = c.name() else {
      throw LinkCError.parse("line \(line): table \(table) has a foreign key that names no table")
    }
    if c.peekSymbol("(") {
      let names = c.nameList()
      if let name = names.first { value.references = .init(table: target, column: name) }
    } else {
      pending.append(.init(table: table, column: column, target: target, line: line))
    }
    while !c.done {
      if c.take("MATCH") {
        c.index += min(1, c.tokens.count - c.index)
      } else if c.take("ON") {
        c.index += min(1, c.tokens.count - c.index)
        if c.take("SET") || c.take("NO") {
          c.index += min(1, c.tokens.count - c.index)
        } else {
          c.index += min(1, c.tokens.count - c.index)
        }
        if c.peekSymbol("(") { _ = c.nameList() }
      } else if c.take("NOT") {
        _ = c.take("DEFERRABLE")
      } else if c.take("DEFERRABLE") {
      } else if c.take("INITIALLY") {
        c.index += min(1, c.tokens.count - c.index)
      } else {
        break
      }
    }
  }

  /// Splits a CREATE TABLE body at top-level commas and rejects empty entries.
  private func split(_ tokens: [SQLToken], table: String) throws -> [[SQLToken]] {
    var result: [[SQLToken]] = []
    var current: [SQLToken] = []
    var depth = 0
    for token in tokens {
      if token.text == "(" || token.text == "[" { depth += 1 }
      if token.text == ")" || token.text == "]" { depth -= 1 }
      if token.text == ",", depth == 0 {
        if current.isEmpty {
          throw LinkCError.parse("line \(token.line): table \(table) has an empty column entry")
        }
        result.append(current)
        current = []
      } else {
        current.append(token)
      }
    }
    if current.isEmpty, let last = tokens.last, last.text == "," {
      throw LinkCError.parse("line \(last.line): table \(table) has an empty column entry")
    }
    if !current.isEmpty { result.append(current) }
    return result
  }
  /// Splits ALTER TABLE actions at commas outside parentheses.
  private func splitTop(_ tokens: [SQLToken]) -> [[SQLToken]] {
    var actions: [[SQLToken]] = []
    var currentAction: [SQLToken] = []
    var depth = 0
    for token in tokens {
      if token.text == "(" { depth += 1 }
      if token.text == ")" { depth -= 1 }
      if token.text == ",", depth == 0 {
        actions.append(currentAction)
        currentAction = []
      } else {
        currentAction.append(token)
      }
    }
    if !currentAction.isEmpty { actions.append(currentAction) }
    return actions
  }
  /// Finds the parenthesis that closes the opening token at `start`.
  private func matchingClose(_ tokens: [SQLToken], from start: Int) -> Int? {
    var depth = 0
    for tokenIndex in start..<tokens.count {
      if tokens[tokenIndex].text == "(" { depth += 1 }
      if tokens[tokenIndex].text == ")" {
        depth -= 1
        if depth == 0 { return tokenIndex }
      }
    }
    return nil
  }
  /// Finds the first top-level token that begins a column constraint.
  private func boundaryIndex(_ tokens: [SQLToken], keywords: Set<String>) -> Int? {
    var depth = 0
    for (tokenIndex, token) in tokens.enumerated() {
      if token.text == "(" || token.text == "[" { depth += 1 }
      if token.text == ")" || token.text == "]" { depth -= 1 }
      if depth == 0, let keyword = token.keyword, keywords.contains(keyword) { return tokenIndex }
    }
    return nil
  }
  /// Canonically renders type and default-expression tokens.
  private func render(_ tokens: [SQLToken]) -> String {
    var filtered: [SQLToken] = []
    var tokenIndex = 0
    while tokenIndex < tokens.count {
      if tokenIndex + 1 < tokens.count, tokens[tokenIndex].value.lowercased() == "public",
        tokens[tokenIndex + 1].text == "."
      {
        tokenIndex += 2
        continue
      }
      filtered.append(tokens[tokenIndex])
      tokenIndex += 1
    }
    var result = ""
    var previous: SQLToken?
    for token in filtered {
      let value =
        token.kind == .word
        ? token.value.lowercased()
        : token.kind == .quotedName ? SQLSchema.quotedIfNeeded(token.value) : token.text
      let noBefore: Set<String> = [")", "]", ",", "[", "::", "."]
      let noAfter: Set<String> = ["(", "[", "::", "."]
      var space = previous != nil && !noBefore.contains(token.text) && !noAfter.contains(previous!.text)
      if token.text == "(", let previousToken = previous,
        previousToken.kind == .word || previousToken.kind == .quotedName
          || ["]", ")", "(", "::", "."].contains(previousToken.text)
      {
        space = false
      }
      if previous?.text == "," { space = true }
      if space { result.append(" ") }
      result.append(value)
      previous = token
    }
    return result
  }
  /// Describes a skipped statement using its first meaningful words.
  private func skippedText(_ tokens: [SQLToken]) -> String {
    var words = tokens.filter { $0.kind == .word }.map { $0.value.uppercased() }
    if words.first == "CREATE", words.dropFirst().prefix(2).elementsEqual(["OR", "REPLACE"]) {
      words.removeSubrange(1...2)
    }
    return words.prefix(2).joined(separator: " ")
  }
  /// Looks up a column in a parsed table.
  private func column(_ table: String, _ name: String) -> BoardColumn? {
    tables.first { $0.name == table }?.columns.first { $0.name == name }
  }
  /// Refuses a constraint or action that names an absent column.
  private mutating func requireColumn(_ table: String, _ name: String, _ line: Int) throws {
    if column(table, name) == nil {
      throw LinkCError.parse("line \(line): table \(table) has no column \(name)")
    }
  }
  /// Mutates a parsed table when it exists.
  private mutating func updateTable(_ name: String, _ body: (inout SQLSchema.Table) -> Void) {
    if let tableIndex = tables.firstIndex(where: { $0.name == name }) { body(&tables[tableIndex]) }
  }
  /// Mutates a named column in a parsed table.
  private mutating func update(
    _ table: String, _ column: String, _ body: (inout BoardColumn) -> Void
  ) {
    updateTable(table) {
      if let columnIndex = $0.columns.firstIndex(where: { $0.name == column }) {
        body(&$0.columns[columnIndex])
      }
    }
  }
  /// Attaches a reference after its implicit target column has been resolved.
  private mutating func setReference(table: String, column: String, reference: BoardColumnReference)
  {
    update(table, column) { $0.references = reference }
  }
}

/// A small token cursor used by the recursive-descent schema parser.
private struct Cursor {
  let tokens: [SQLToken]
  var index = 0
  var previousLine = 1
  init(_ tokens: [SQLToken]) { self.tokens = tokens }
  var done: Bool { index >= tokens.count }
  var current: SQLToken? { done ? nil : tokens[index] }
  /// Tests the current token for an unquoted keyword.
  func peek(_ keyword: String) -> Bool { current?.keyword == keyword }
  /// Tests the current token for exact punctuation.
  func peekSymbol(_ symbol: String) -> Bool { current?.text == symbol }
  /// Tests upcoming keywords without consuming them.
  func matches(_ keywords: String...) -> Bool {
    guard index + keywords.count <= tokens.count else { return false }
    return zip(tokens[index..<index + keywords.count], keywords).allSatisfy { $0.keyword == $1 }
  }
  /// Consumes an unquoted keyword when it matches.
  mutating func take(_ keyword: String) -> Bool {
    guard peek(keyword) else { return false }
    previousLine = tokens[index].line
    index += 1
    return true
  }
  /// Consumes punctuation when it matches.
  mutating func takeSymbol(_ symbol: String) -> Bool {
    guard peekSymbol(symbol) else { return false }
    previousLine = tokens[index].line
    index += 1
    return true
  }
  /// Consumes one quoted or unquoted identifier part.
  mutating func columnName() -> String? {
    guard let token = current, token.kind == .word || token.kind == .quotedName else { return nil }
    index += 1
    return token.kind == .word ? token.value.lowercased() : token.value
  }
  /// Consumes a one- or two-part table name, dropping the public schema.
  mutating func name() -> String? {
    guard let first = columnName() else { return nil }
    if takeSymbol("."), let second = columnName() {
      return first == "public" ? second : "\(first).\(second)"
    }
    return first
  }
  /// Consumes a parenthesized, comma-separated identifier list.
  mutating func nameList() -> [String] {
    guard takeSymbol("(") else { return [] }
    var names: [String] = []
    while !done, !takeSymbol(")") {
      if let name = columnName() { names.append(name) } else { index += 1 }
      _ = takeSymbol(",")
    }
    return names
  }
  /// Consumes one balanced parenthesized clause.
  mutating func skipBalanced() {
    guard takeSymbol("(") else { return }
    var depth = 1
    while !done, depth > 0 {
      if takeSymbol("(") { depth += 1 } else if takeSymbol(")") { depth -= 1 } else { index += 1 }
    }
  }
}
