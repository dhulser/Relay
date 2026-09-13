import XCTest
import Combine
@testable import Relay

@MainActor
final class SubtitleManagerTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// A finished line must not wait on the debounce timer — it's the one
    /// update guaranteed never to change again.
    func testCompletedLineAppearsImmediately() {
        let manager = SubtitleManager()
        manager.complete("I'll send you the report tomorrow.")

        XCTAssertEqual(manager.history.map(\.text), ["I'll send you the report tomorrow."])
        XCTAssertTrue(manager.current.isEmpty)
    }

    /// Two finished lines plus the in-flight one gives the three visible rows
    /// the design asks for; older lines have to fall off.
    func testHistoryIsCappedAtTwoLines() {
        let manager = SubtitleManager()
        manager.complete("first")
        manager.complete("second")
        manager.complete("third")

        XCTAssertEqual(manager.history.map(\.text), ["second", "third"])
    }

    /// Finishing an utterance clears whatever partial text was on screen, so a
    /// half-translated phrase can't linger under the finished line.
    func testCompletingClearsInFlightText() {
        let manager = SubtitleManager()
        manager.updatePartial("I'll send")
        manager.complete("I'll send you the report.")

        XCTAssertTrue(manager.current.isEmpty)
        XCTAssertEqual(manager.history.count, 1)
    }

    /// The point of the whole class: token-rate updates must not become
    /// redraw-rate updates. Twenty deltas over ~400 ms should coalesce into a
    /// handful of publishes, not twenty.
    func testRapidPartialsCoalesce() {
        let manager = SubtitleManager()
        var updates = 0

        manager.$current
            .dropFirst()          // ignore the initial empty value
            .sink { _ in updates += 1 }
            .store(in: &cancellables)

        let words = ["I", "I'll", "I'll send", "I'll send you", "I'll send you the",
                     "I'll send you the report"]
        let finished = expectation(description: "partials delivered")

        // Fire 20 deltas ~20 ms apart, which is roughly what a streaming
        // response looks like.
        for index in 0..<20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.02) {
                manager.updatePartial(words[index % words.count] + String(repeating: ".", count: index))
                if index == 19 { finished.fulfill() }
            }
        }

        wait(for: [finished], timeout: 3)
        // Allow the last debounce window to land.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertGreaterThan(updates, 0, "partial text should reach the view at least once")
        XCTAssertLessThan(updates, 10, "20 deltas coalesced into \(updates) redraws — too many")
    }

    /// The very first line has nothing to be a turn break from.
    func testFirstLineIsNeverATurnBreak() {
        let manager = SubtitleManager()
        manager.updatePartial("hola")
        manager.complete("hello")

        XCTAssertEqual(manager.history.count, 1)
        XCTAssertFalse(manager.history[0].startsNewTurn)
    }

    /// One person talking straight through must not be chopped into turns.
    func testBackToBackLinesAreTheSameTurn() {
        let manager = SubtitleManager()
        manager.updatePartial("uno")
        manager.complete("one")
        manager.updatePartial("dos")
        manager.complete("two")

        XCTAssertEqual(manager.history.count, 2)
        XCTAssertFalse(manager.history[1].startsNewTurn,
                       "no pause between these, so they are one speaker's turn")
    }

    /// A gap longer than the turn threshold marks the next line as a new turn.
    func testSilenceBetweenUtterancesStartsANewTurn() {
        let manager = SubtitleManager()
        manager.updatePartial("uno")
        manager.complete("one")

        let paused = expectation(description: "silence elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { paused.fulfill() }
        wait(for: [paused], timeout: 4)

        manager.updatePartial("dos")
        manager.complete("two")

        XCTAssertEqual(manager.history.count, 2)
        XCTAssertTrue(manager.history[1].startsNewTurn,
                      "a 1.7s silence should read as a turn change")
    }

    func testClearEmptiesEverything() {
        let manager = SubtitleManager()
        manager.complete("something")
        manager.updatePartial("in flight")
        manager.clear()

        XCTAssertTrue(manager.history.isEmpty)
        XCTAssertTrue(manager.current.isEmpty)
        XCTAssertTrue(manager.isEmpty)
    }

    func testBlankTextIsIgnored() {
        let manager = SubtitleManager()
        manager.complete("   \n  ")
        manager.updatePartial("")

        XCTAssertTrue(manager.isEmpty)
    }
}
