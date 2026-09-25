import XCTest
@testable import LinkCKit

final class BoardInspectionTests: XCTestCase {
    /// Shaped like the RISC-V Register File: three buses in, a control signal in, three buses out.
    private func map() -> BoardMap {
        var m = BoardMap()
        m.components = [
            BoardComponent(name: "Instruction Memory", kind: .ram,
                           uses: ["Register File": BoardArrow(label: "rs1, rs2, rd", style: .bus, bits: 15)]),
            BoardComponent(name: "Control Unit", kind: .control, uses: ["Register File": BoardArrow(label: "RegWrite", style: .control)]),
            BoardComponent(name: "Writeback Mux", kind: .mux, uses: ["Register File": BoardArrow(label: "write data", style: .bus, bits: 32)]),
            BoardComponent(name: "Register File", kind: .register, does: "32 x 32-bit, two read ports, one write port", planned: true,
                           uses: ["ALU": BoardArrow(label: "rs1 data", style: .bus, bits: 32),
                                  "Data Memory": BoardArrow(label: "store data", style: .bus, bits: 32),
                                  "ALU Operand Mux": BoardArrow(label: "", style: .bus, bits: 32)]),
            BoardComponent(name: "ALU", kind: .alu),
            BoardComponent(name: "ALU Operand Mux", kind: .mux),
            BoardComponent(name: "Data Memory", kind: .ram, planned: true),
        ]
        return m
    }

    func testAPartListsItsInputsAndOutputsInOrder() throws {
        let part = try XCTUnwrap(BoardInspection.part("Register File", in: map()))
        XCTAssertEqual(part.kind, .register)
        XCTAssertTrue(part.planned)
        XCTAssertEqual(part.does, "32 x 32-bit, two read ports, one write port")
        XCTAssertEqual(part.inputs.map(\.other), ["Control Unit", "Instruction Memory", "Writeback Mux"])
        XCTAssertEqual(part.inputs.map(\.signal), ["RegWrite", "rs1, rs2, rd", "write data"])
        XCTAssertEqual(part.inputs.map(\.bits), [nil, 15, 32])
        XCTAssertEqual(part.inputs.map(\.isControl), [true, false, false])
        XCTAssertEqual(part.outputs.map(\.other), ["ALU", "ALU Operand Mux", "Data Memory"])
        XCTAssertEqual(part.outputs.map(\.signal), ["rs1 data", "ALU Operand Mux", "store data"],
                       "an arrow with no label is named after its other end")
    }

    func testAnArrowCardNamesItsEndsAndItsPlannedEnds() throws {
        let card = try XCTUnwrap(BoardInspection.arrow(BoardModel.ArrowKey(from: "Register File", to: "Data Memory"), in: map()))
        XCTAssertEqual(card.from, "Register File")
        XCTAssertEqual(card.to, "Data Memory")
        XCTAssertEqual(card.label, "store data")
        XCTAssertEqual(card.bits, 32)
        XCTAssertEqual(card.style, .bus)
        XCTAssertEqual(card.plannedEnds, ["Register File", "Data Memory"])
    }

    func testAnUnknownPartOrArrowHasNoCard() {
        XCTAssertNil(BoardInspection.part("Nope", in: map()))
        XCTAssertNil(BoardInspection.arrow(BoardModel.ArrowKey(from: "ALU", to: "Nope"), in: map()))
    }
}
