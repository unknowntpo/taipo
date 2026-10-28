import Foundation
import Testing
@testable import TaipoDecision

@Test("D8: a missing model directory is reported as an error, not a crash")
func missingModel() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-no-model-\(UUID().uuidString)")
    await #expect(throws: ClefMini.LoadError.self) { _ = try await ClefMini.load(directory: missing) }
}
