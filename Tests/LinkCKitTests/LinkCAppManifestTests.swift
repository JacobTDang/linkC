import XCTest
@testable import LinkCKit

final class LinkCAppManifestTests: XCTestCase {
    private func decode(_ json: String) throws -> LinkCAppManifest {
        try LinkCAppManifest.decode(Data(json.utf8))
    }

    private func error(_ json: String) -> String {
        do {
            _ = try decode(json)
            return "no error"
        } catch {
            return error.localizedDescription
        }
    }

    func testAValidManifestDecodes() throws {
        let manifest = try decode("""
            {"name": "Circuit MCP", "start": ["uv", "run", "run_ui.py", "--port", "{port}"],
             "health": "/healthz", "path": "/desk", "env": {"MODE": "linkc"}, "unknown": 1}
            """)
        XCTAssertEqual(manifest.name, "Circuit MCP")
        XCTAssertEqual(manifest.start, ["uv", "run", "run_ui.py", "--port", "{port}"])
        XCTAssertEqual(manifest.health, "/healthz")
        XCTAssertEqual(manifest.path, "/desk")
        XCTAssertEqual(manifest.env, ["MODE": "linkc"])
    }

    func testPathAndEnvAreOptional() throws {
        let manifest = try decode(#"{"name": "A", "start": ["a"], "health": "/"}"#)
        XCTAssertEqual(manifest.path, "/")
        XCTAssertEqual(manifest.env, [:])
    }

    func testEachBadFieldIsNamed() {
        XCTAssertTrue(error("[1]").contains("JSON object"))
        XCTAssertTrue(error("{").contains("not valid JSON"))
        XCTAssertTrue(error(#"{"start": ["a"], "health": "/"}"#).contains("\"name\""))
        XCTAssertTrue(error(#"{"name": " ", "start": ["a"], "health": "/"}"#).contains("\"name\""))
        XCTAssertTrue(error(#"{"name": "A", "health": "/"}"#).contains("\"start\""))
        XCTAssertTrue(error(#"{"name": "A", "start": [], "health": "/"}"#).contains("\"start\""))
        XCTAssertTrue(error(#"{"name": "A", "start": ["a", 2], "health": "/"}"#).contains("\"start\""))
        XCTAssertTrue(error(#"{"name": "A", "start": ["a"]}"#).contains("\"health\""))
        XCTAssertTrue(error(#"{"name": "A", "start": ["a"], "health": "healthz"}"#).contains("\"health\""))
        XCTAssertTrue(error(#"{"name": "A", "start": ["a"], "health": "/", "path": "desk"}"#).contains("\"path\""))
        XCTAssertTrue(error(#"{"name": "A", "start": ["a"], "health": "/", "env": {"K": 1}}"#).contains("\"env\""))
    }

    func testLaunchReplacesThePortEverywhereAndSetsLinkCPort() throws {
        let manifest = LinkCAppManifest(
            name: "A", start: ["sh", "-c", "serve --port {port} --url http://127.0.0.1:{port}"],
            health: "/healthz", path: "/desk", env: ["MODE": "x"])
        let launch = try manifest.launch(port: 4321)
        XCTAssertEqual(launch.argv, ["sh", "-c", "serve --port 4321 --url http://127.0.0.1:4321"])
        XCTAssertEqual(launch.environment, ["MODE": "x", "LINKC_PORT": "4321"])
        XCTAssertEqual(launch.healthURL.absoluteString, "http://127.0.0.1:4321/healthz")
        XCTAssertEqual(launch.pageURL.absoluteString, "http://127.0.0.1:4321/desk?linkc=1")
    }

    func testThePageKeepsItsOwnQuery() throws {
        let manifest = LinkCAppManifest(name: "A", start: ["a"], health: "/", path: "/desk?tab=2")
        XCTAssertEqual(try manifest.launch(port: 1).pageURL.absoluteString, "http://127.0.0.1:1/desk?tab=2&linkc=1")
    }
}
