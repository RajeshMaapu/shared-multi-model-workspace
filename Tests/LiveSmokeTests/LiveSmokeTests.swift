import XCTest
@testable import WorkshopCore

final class LiveSmokeTests: XCTestCase {
    func testLiveSmokeOptIn() throws {
        throw XCTSkip("Live smoke tests are opt-in: set WORKSHOP_LIVE=1. No live adapters exist in Phase 1.")
    }
}
