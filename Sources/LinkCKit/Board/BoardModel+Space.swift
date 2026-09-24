import Foundation

extension BoardModel {
    public func rect(of element: Element) -> BoardRect? {
        switch element {
        case .component(let name):
            return Self.index(of: name, in: map).flatMap { map.components[$0].at }.map(BoardGeometry.rect(ofComponentAt:))
        case .frame(let label):
            return map.frames.first { $0.label == label }?.rect
        case .note(let id):
            return map.notes.first { $0.id == id }?.at.map(BoardGeometry.rect(ofNoteAt:))
        case .text(let id):
            return map.texts.first { $0.id == id }.map(BoardGeometry.rect(of:))
        case .arrow:
            return nil
        }
    }

    /// Moves the elements by `delta`, then settles them: frames first — each carrying its
    /// components and any note or text wholly inside it — then everything else, each sliding
    /// clear of what is already settled and taking the place its centre lands in. One undo step;
    /// a move of nothing is not an edit.
    public func move(_ elements: Set<Element>, by delta: BoardPoint) {
        guard delta.x != 0 || delta.y != 0 else { return }
        edit { map in
            let frames = elements.compactMap { element -> String? in
                if case .frame(let label) = element { return label } else { return nil }
            }.sorted()
            // Every component, note and text in this same move — whether a frame ends up
            // carrying it or it stays loose — must not act as an obstacle at its old spot while
            // a frame in the same move settles; the same rule I3 applies among loose elements.
            let movingContent: Set<Element> = Set(elements.filter { element in
                switch element {
                case .component, .note, .text: return true
                case .frame, .arrow: return false
                }
            })
            var carried: Set<Element> = []
            var changed = false
            // Every frame in this same move is left out of the obstacles up front — checking it
            // against a sibling's *old* spot, before that sibling has landed, is what scrambles a
            // group move. Each frame's landing spot joins the obstacles right after, for the rest.
            let untouchedFrames = Self.frameRects(map, excluding: Set(frames))
            var settledFrames: [BoardRect] = []

            for label in frames {
                guard let index = map.frames.firstIndex(where: { $0.label == label }), let rect = map.frames[index].rect else { continue }
                let interior = BoardGeometry.interior(of: rect)
                let members = Set(map.components.filter { $0.place == label }.map(\.name))
                let notes = Set(map.notes.filter { $0.at.map { interior.contains(BoardGeometry.rect(ofNoteAt: $0)) } ?? false }.map(\.id))
                let texts = Set(map.texts.filter { interior.contains(BoardGeometry.rect(of: $0)) }.map(\.id))
                let riders = Set(members.map { Element.component($0) })
                    .union(notes.map { Element.note($0) })
                    .union(texts.map { Element.text($0) })
                let landed = BoardGeometry.frameDrop(
                    rect.offsetBy(dx: delta.x, dy: delta.y).snapped,
                    otherFrames: untouchedFrames + settledFrames,
                    foreignElements: Self.elementRects(map, excluding: riders.union(movingContent)))
                settledFrames.append(landed)
                let dx = landed.x - rect.x
                let dy = landed.y - rect.y
                guard dx != 0 || dy != 0 else { continue }
                map.frames[index].rect = landed
                for i in map.components.indices where members.contains(map.components[i].name) {
                    if let at = map.components[i].at { map.components[i].at = BoardPoint(x: at.x + dx, y: at.y + dy) }
                }
                for i in map.notes.indices where notes.contains(map.notes[i].id) {
                    if let at = map.notes[i].at { map.notes[i].at = BoardPoint(x: at.x + dx, y: at.y + dy) }
                }
                for i in map.texts.indices where texts.contains(map.texts[i].id) {
                    map.texts[i].at = BoardPoint(x: map.texts[i].at.x + dx, y: map.texts[i].at.y + dy)
                }
                carried.formUnion(riders)
                changed = true
            }

            let loose = elements.filter { element in
                switch element {
                case .component, .note, .text: return !carried.contains(element)
                case .frame, .arrow: return false
                }
            }
            // Same principle as the frames above: every loose element in this move is left out of
            // the obstacles up front, so one is never checked against a sibling's old spot — only
            // against things not part of this move, and siblings that have already landed.
            let untouchedElements = Self.elementRects(map, excluding: Set(loose))
            let frameRects = Self.frameRects(map, excluding: [])
            var settledElements: [BoardRect] = []
            for element in loose.sorted(by: { Self.sortKey($0) < Self.sortKey($1) }) {
                let others = untouchedElements + settledElements
                switch element {
                case .component(let name):
                    guard let index = Self.index(of: name, in: map), let at = map.components[index].at else { continue }
                    let landed = BoardGeometry.elementDrop(
                        BoardGeometry.rect(ofComponentAt: at).offsetBy(dx: delta.x, dy: delta.y).snapped,
                        otherElements: others, frames: frameRects)
                    map.components[index].at = landed.origin
                    map.components[index].place = BoardGeometry.frame(containing: landed, frames: map.frames)?.label ?? BoardMap.notPlaced
                    changed = changed || landed.origin != at
                    settledElements.append(landed)
                case .note(let id):
                    guard let index = map.notes.firstIndex(where: { $0.id == id }), let at = map.notes[index].at else { continue }
                    let landed = BoardGeometry.elementDrop(
                        BoardGeometry.rect(ofNoteAt: at).offsetBy(dx: delta.x, dy: delta.y).snapped,
                        otherElements: others, frames: frameRects)
                    map.notes[index].at = landed.origin
                    changed = changed || landed.origin != at
                    settledElements.append(landed)
                case .text(let id):
                    guard let index = map.texts.firstIndex(where: { $0.id == id }) else { continue }
                    let text = map.texts[index]
                    let landed = BoardGeometry.elementDrop(
                        BoardGeometry.rect(of: text).offsetBy(dx: delta.x, dy: delta.y).snapped,
                        otherElements: others, frames: frameRects)
                    map.texts[index].at = landed.origin
                    changed = changed || landed.origin != text.at
                    settledElements.append(landed)
                case .frame, .arrow:
                    continue
                }
            }
            return changed
        }
    }

    /// Everything on the board as one rect — what "fit everything" shows. nil for an empty board.
    public var contentBounds: BoardRect? {
        let rects = Self.elementRects(map, excluding: []) + Self.frameRects(map, excluding: [])
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { union, rect in
            let minX = min(union.minX, rect.minX), minY = min(union.minY, rect.minY)
            return BoardRect(x: minX, y: minY, w: max(union.maxX, rect.maxX) - minX, h: max(union.maxY, rect.maxY) - minY)
        }
    }

    /// Resizes a frame from its bottom-right corner, within `BoardGeometry.frameResize`'s limits.
    public func resizeFrame(_ label: String, to proposed: BoardRect) {
        edit { map in
            guard let index = map.frames.firstIndex(where: { $0.label == label }), let original = map.frames[index].rect else { return false }
            let interior = BoardGeometry.interior(of: original)
            let members = map.components.filter { $0.place == label }
            let memberRects = members.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) }
                + map.notes.compactMap { $0.at.map(BoardGeometry.rect(ofNoteAt:)) }.filter { interior.contains($0) }
                + map.texts.map(BoardGeometry.rect(of:)).filter { interior.contains($0) }
            let foreign = Self.elementRects(map, excluding: Set(members.map { .component($0.name) })).filter { !original.contains($0) }
            let resized = BoardGeometry.frameResize(
                proposed.snapped, original: original, members: memberRects,
                otherFrames: Self.frameRects(map, excluding: [label]), foreignElements: foreign)
            guard resized != original else { return false }
            map.frames[index].rect = resized
            return true
        }
    }

    /// Gives everything the file left without a place on the board one: a rect for each frame
    /// (sized for its components, in a row to the right of what is already laid out), a
    /// position inside its own frame for each component (the file's place wins over a stray
    /// position), and room for every note and text — nothing overlapping. Pure and idempotent.
    public nonisolated static func laidOut(_ source: BoardMap) -> BoardMap {
        var map = source
        let size = BoardGeometry.componentSize
        let gap = 16

        func contentRight() -> Int {
            (frameRects(map, excluding: []) + elementRects(map, excluding: [])).map(\.maxX).max() ?? 0
        }

        // Frames: every frame gets a rect, in label order.
        for index in map.frames.indices.sorted(by: { map.frames[$0].label < map.frames[$1].label }) where map.frames[index].rect == nil {
            let count = max(1, map.components.filter { $0.place == map.frames[index].label }.count)
            let columns = min(2, count)
            let rows = (count + columns - 1) / columns
            let wanted = BoardRect(x: 0, y: 0,
                                   w: max(BoardGeometry.frameMinSize.x, columns * (size.x + gap) + gap),
                                   h: max(BoardGeometry.frameMinSize.y, rows * (size.y + gap) + gap)).snapped
            let seed = wanted.offsetBy(dx: contentRight() + (contentRight() == 0 ? 0 : 48), dy: 0).snapped
            map.frames[index].rect = BoardGeometry.frameDrop(
                seed, otherFrames: frameRects(map, excluding: [map.frames[index].label]), foreignElements: elementRects(map, excluding: []))
        }

        // Frames that already had a rect in the file can still overlap one another — after a git
        // merge, say. Each is nudged to the nearest free spot, in label order, carrying its own
        // components, notes and texts along with it, exactly as a frame move does. Whether a
        // frame needs to move at all is judged against the frames already settled — an earlier
        // one in label order never moves for a later one's sake — but once it does move, every
        // other frame, settled or not yet reached, is an obstacle, so escaping one overlap can
        // never land it on a frame that was never involved.
        var settledFrames: [BoardRect] = []
        for index in map.frames.indices.sorted(by: { map.frames[$0].label < map.frames[$1].label }) {
            guard let rect = map.frames[index].rect else { continue }
            guard settledFrames.contains(where: { $0.intersects(rect) }) else {
                settledFrames.append(rect)
                continue
            }
            let otherFrames = map.frames.indices.compactMap { $0 == index ? nil : map.frames[$0].rect }
            let landed = BoardGeometry.frameDrop(rect, otherFrames: otherFrames, foreignElements: elementRects(map, excluding: []))
            settledFrames.append(landed)
            let dx = landed.x - rect.x
            let dy = landed.y - rect.y
            guard dx != 0 || dy != 0 else { continue }
            map.frames[index].rect = landed
            let label = map.frames[index].label
            let interior = BoardGeometry.interior(of: rect)
            for i in map.components.indices where map.components[i].place == label {
                if let at = map.components[i].at { map.components[i].at = BoardPoint(x: at.x + dx, y: at.y + dy) }
            }
            for i in map.notes.indices {
                if let at = map.notes[i].at, interior.contains(BoardGeometry.rect(ofNoteAt: at)) {
                    map.notes[i].at = BoardPoint(x: at.x + dx, y: at.y + dy)
                }
            }
            for i in map.texts.indices where interior.contains(BoardGeometry.rect(of: map.texts[i])) {
                map.texts[i].at = BoardPoint(x: map.texts[i].at.x + dx, y: map.texts[i].at.y + dy)
            }
        }

        // Components: each settles inside its own place's frame, or outside every frame.
        for index in map.components.indices.sorted(by: { map.components[$0].name < map.components[$1].name }) {
            let component = map.components[index]
            let frame = map.frames.first { $0.label == component.place }?.rect
            // A place naming no frame is stale — unplaced for positioning, and cleared here so it
            // never again reads as a heading for a frame that is not there.
            if frame == nil, component.place != BoardMap.notPlaced {
                map.components[index].place = BoardMap.notPlaced
            }
            let others = elementRects(map, excluding: [.component(component.name)])
            let current = component.at.map(BoardGeometry.rect(ofComponentAt:))
            if let frame {
                let interior = BoardGeometry.interior(of: frame)
                if let current, interior.contains(current), !others.contains(where: { $0.intersects(current) }) { continue }
                let seed = BoardRect(x: interior.x, y: interior.y, w: size.x, h: size.y)
                let members = map.components.filter { $0.place == component.place && $0.name != component.name }
                var spot = BoardGeometry.nearestFreeSpot(for: current.map { interior.contains($0) ? $0 : seed } ?? seed,
                                                         avoiding: others, inside: interior)
                if spot == nil, let frameIndex = map.frames.firstIndex(where: { $0.label == component.place }),
                   let grown = BoardGeometry.grow(frame, toFit: size,
                                                  members: members.compactMap { $0.at.map(BoardGeometry.rect(ofComponentAt:)) },
                                                  otherFrames: frameRects(map, excluding: [component.place]),
                                                  foreignElements: elementRects(map, excluding: Set(members.map { .component($0.name) } + [.component(component.name)])).filter { !frame.contains($0) }) {
                    map.frames[frameIndex].rect = grown
                    spot = BoardGeometry.nearestFreeSpot(for: seed, avoiding: others, inside: BoardGeometry.interior(of: grown))
                }
                if let spot {
                    map.components[index].at = spot.origin
                    continue
                }
                map.components[index].place = BoardMap.notPlaced
            }
            let frames = frameRects(map, excluding: [])
            if let current, !frames.contains(where: { $0.intersects(current) }), !others.contains(where: { $0.intersects(current) }) { continue }
            let seed = current ?? BoardRect(x: 0, y: (frames.map(\.maxY).max() ?? 0) + 48, w: size.x, h: size.y)
            map.components[index].at = (BoardGeometry.nearestFreeSpot(for: seed, avoiding: others, outside: frames) ?? seed).origin
        }

        // Notes and texts: kept where they are when that is allowed, else settled by the same drop
        // rule a hand-placed one follows — so a note wholly inside a frame stays there.
        let bottom = (frameRects(map, excluding: []) + elementRects(map, excluding: [])).map(\.maxY).max() ?? 0
        for index in map.notes.indices {
            let note = map.notes[index]
            let seed = note.at.map(BoardGeometry.rect(ofNoteAt:))
                ?? BoardRect(x: 0, y: bottom + 48, w: BoardGeometry.noteSize.x, h: BoardGeometry.noteSize.y)
            map.notes[index].at = BoardGeometry.elementDrop(
                seed, otherElements: elementRects(map, excluding: [.note(note.id)]), frames: frameRects(map, excluding: [])).origin
        }
        for index in map.texts.indices {
            let text = map.texts[index]
            map.texts[index].at = BoardGeometry.elementDrop(
                BoardGeometry.rect(of: text), otherElements: elementRects(map, excluding: [.text(text.id)]),
                frames: frameRects(map, excluding: [])).origin
        }

        // A component whose box now overlaps an earlier component's box — grown into it by a
        // component-size change, say — moves clear, keeping its frame by containment. This keeps
        // a board written by an older linkC valid without ever touching the file on disk.
        for index in map.components.indices.sorted(by: { map.components[$0].name < map.components[$1].name }) {
            guard let at = map.components[index].at else { continue }
            let name = map.components[index].name
            let current = BoardGeometry.rect(ofComponentAt: at)
            let earlier = map.components.indices
                .filter { map.components[$0].name < name }
                .compactMap { map.components[$0].at.map(BoardGeometry.rect(ofComponentAt:)) }
            guard earlier.contains(where: { $0.intersects(current) }) else { continue }
            let landed = BoardGeometry.elementDrop(
                current, otherElements: elementRects(map, excluding: [.component(name)]), frames: frameRects(map, excluding: []))
            map.components[index].at = landed.origin
            map.components[index].place = BoardGeometry.frame(containing: landed, frames: map.frames)?.label ?? BoardMap.notPlaced
        }
        return map
    }

    private static func sortKey(_ element: Element) -> String {
        switch element {
        case .component(let name): return "1:\(name)"
        case .note(let id): return "2:\(id.uuidString)"
        case .text(let id): return "3:\(id.uuidString)"
        case .frame(let label): return "0:\(label)"
        case .arrow(let arrow): return "4:\(arrow.from)>\(arrow.to)"
        }
    }
}
