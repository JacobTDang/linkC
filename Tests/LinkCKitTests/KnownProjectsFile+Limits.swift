import Foundation
@testable import LinkCKit

extension KnownProjectsFile {
    /// The plan limits the file lists, decoded from its JSON as a client of `projects.json` reads
    /// them: the app writes them and never reads them back.
    func writtenLimits() throws -> [String: [KnownLimit]] {
        struct Limits: Decodable { let limits: [String: [KnownLimit]]? }
        return try JSONDecoder().decode(Limits.self, from: Data(contentsOf: url)).limits ?? [:]
    }
}
