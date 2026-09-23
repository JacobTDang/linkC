import XCTest
@testable import LinkCKit

final class BoardReconcilerTests: XCTestCase {
    private func thing(_ name: String, image: String? = nil) -> DiscoveredThing {
        DiscoveredThing(name: name, image: image, detail: "container \(name)")
    }

    private func status(_ map: BoardMap, _ discovered: [DiscoveredThing], _ name: String) -> ComponentStatus? {
        BoardReconciler.reconcile(map: map, discovered: discovered).statuses[name]
    }

    func testAComponentThatMatchesSomethingRunningIsPresent() {
        var map = BoardMap.empty
        map.components = [
            BoardComponent(name: "postgres", kind: .database, runs: "docker compose (db)"),
        ]
        XCTAssertEqual(status(map, [thing("postgres")], "postgres"), .present)
    }

    func testMatchingIgnoresCase() {
        var map = BoardMap.empty
        map.components = [BoardComponent(name: "Postgres", kind: .database, runs: "docker")]
        XCTAssertEqual(status(map, [thing("postgres")], "Postgres"), .present)
    }

    func testAComponentIsMatchedByWhatItsRunsTextNames() {
        var map = BoardMap.empty
        map.components = [
            BoardComponent(name: "primary store", kind: .database, runs: "docker compose (db)"),
        ]
        XCTAssertEqual(status(map, [thing("db")], "primary store"), .present)
    }

    /// Only a component that says it runs where linkC can look may be reported missing.
    func testAComponentThatRunsInDockerButIsNotThereIsMissing() {
        var map = BoardMap.empty
        map.components = [
            BoardComponent(name: "redis", kind: .cache, runs: "docker compose (redis)"),
        ]
        XCTAssertEqual(status(map, [], "redis"), .missing)
    }

    /// Absence of evidence is not absence: linkC cannot see an Oracle box or a Supabase project.
    func testAComponentLinkCCannotCheckIsUnchecked() {
        var map = BoardMap.empty
        map.components = [
            BoardComponent(name: "june-audio", kind: .host, runs: "Oracle box"),
            BoardComponent(name: "sprout", kind: .database, runs: nil),
        ]
        XCTAssertEqual(status(map, [], "june-audio"), .unchecked)
        XCTAssertEqual(status(map, [], "sprout"), .unchecked)
    }

    /// A component that is only planned is never reported as missing.
    func testAnIntendedComponentIsNeverMissing() {
        var map = BoardMap.empty
        map.components = [
            BoardComponent(name: "redis", kind: .cache, runs: "docker compose (redis)", planned: true),
        ]
        XCTAssertEqual(status(map, [], "redis"), .unchecked)
    }

    func testSomethingRunningThatTheMapDoesNotNameIsSuggested() {
        var map = BoardMap.empty
        map.components = [BoardComponent(name: "api", kind: .service, runs: "docker")]
        let result = BoardReconciler.reconcile(
            map: map, discovered: [thing("api"), thing("minio", image: "minio/minio:latest")])

        XCTAssertEqual(result.suggestions.map(\.name), ["minio"])
        XCTAssertEqual(result.suggestions.first?.kind, .storage)
        XCTAssertEqual(result.suggestions.first?.detail, "container minio")
    }

    func testTheProposedKindComesFromTheImage() {
        let cases: [(String?, ComponentKind)] = [
            ("postgres:16", .database), ("mysql", .database), ("mariadb:11", .database),
            ("redis:7-alpine", .cache), ("memcached", .cache),
            ("rabbitmq:3-management", .queue), ("nats:latest", .queue), ("bitnami/kafka", .queue),
            ("minio/minio", .storage),
            ("ghcr.io/jacob/june-api:sha-9f2", .service), (nil, .service),
        ]
        for (image, expected) in cases {
            XCTAssertEqual(BoardReconciler.kind(forImage: image), expected, image ?? "nil")
        }
    }

    func testAnEmptyMapSuggestsEverythingRunning() {
        let result = BoardReconciler.reconcile(map: .empty, discovered: [thing("a"), thing("b")])
        XCTAssertEqual(result.suggestions.map(\.name), ["a", "b"])
        XCTAssertTrue(result.statuses.isEmpty)
    }

    // MARK: - Finding 1: a parenthetical naming several things names each of them

    /// "docker compose (api, worker)" must match either name, not the combined "api, worker" text.
    func testAParentheticalNamingSeveralThingsNamesEachOfThem() {
        var map = BoardMap.empty
        map.components = [
            BoardComponent(name: "background", kind: .service, runs: "docker compose (api, worker)"),
        ]
        XCTAssertEqual(status(map, [thing("worker")], "background"), .present)
        XCTAssertEqual(status(map, [thing("api")], "background"), .present)
    }

    // MARK: - Finding 2: a digest-pinned image guesses the right kind

    func testDigestPinnedImageGuessesFromRepositoryName() {
        XCTAssertEqual(
            BoardReconciler.kind(forImage: "redis@sha256:9f2c1d0e5e3a4b7c8d9e0f1a2b3c4d5e"), .cache)
    }

    func testRegistryHostWithPortGuessesFromRepositoryName() {
        XCTAssertEqual(BoardReconciler.kind(forImage: "localhost:5000/redis:7"), .cache)
    }

    func testImageWithNoTagGuessesFromRepositoryName() {
        XCTAssertEqual(BoardReconciler.kind(forImage: "redis"), .cache)
    }

    func testEmptyImageStringFallsBackToService() {
        XCTAssertEqual(BoardReconciler.kind(forImage: ""), .service)
    }

    // MARK: - Finding 3: one running thing backs at most one component, and never both suggested and matched

    /// The first component in the map's order claims a shared running thing; whichever component
    /// is listed first must win, so the result cannot depend on discovery or component order.
    func testOnlyTheFirstMatchingComponentClaimsARunningThing() {
        let discovered = [thing("app")]
        let web = BoardComponent(name: "web", kind: .service, runs: "docker compose (app)")
        let mirror = BoardComponent(name: "web-mirror", kind: .service, runs: "docker compose (app)")

        var webFirst = BoardMap.empty
        webFirst.components = [web, mirror]
        XCTAssertEqual(status(webFirst, discovered, "web"), .present)
        XCTAssertEqual(status(webFirst, discovered, "web-mirror"), .missing)

        var mirrorFirst = BoardMap.empty
        mirrorFirst.components = [mirror, web]
        XCTAssertEqual(status(mirrorFirst, discovered, "web-mirror"), .present)
        XCTAssertEqual(status(mirrorFirst, discovered, "web"), .missing)
    }

    /// A running container literally named "api" is never offered as "not on the map" once the
    /// map already names "api" — even though that component matched a different container by
    /// its `runs` text.
    func testARunningThingMatchingAComponentNameIsNeverSuggestedEvenWhenMatchedElsewhere() {
        var map = BoardMap.empty
        map.components = [
            BoardComponent(name: "api", kind: .service, runs: "docker compose (worker)"),
        ]
        let discovered = [thing("worker"), thing("api")]
        let result = BoardReconciler.reconcile(map: map, discovered: discovered)

        XCTAssertEqual(status(map, discovered, "api"), .present)
        XCTAssertTrue(result.suggestions.isEmpty)
    }

    /// A component linkC was told lives in a docker frame is checkable even with no `runs`.
    func testAPlaceNamingDockerMakesItsComponentsCheckable() {
        var map = BoardMap.empty
        map.frames = [BoardFrame(label: "Local docker")]
        map.components = [
            BoardComponent(name: "redis", kind: .cache, place: "Local docker"),
            BoardComponent(name: "june-audio", kind: .host, place: "Oracle box"),
        ]
        let result = BoardReconciler.reconcile(map: map, discovered: [])
        XCTAssertEqual(result.statuses["redis"], .missing)
        XCTAssertEqual(result.statuses["june-audio"], .unchecked)
    }
}
