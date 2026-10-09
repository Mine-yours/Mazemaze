import XCTest
@testable import MazemazeCore

final class BarVisibilityTests: XCTestCase {
    /// Scrolls through `offsets` one step per 0.05 s starting at `t`.
    private func run(_ v: inout BarVisibility, _ offsets: [Double], min: Double = -100, t: Double = 10) {
        var now = t
        for o in offsets { v.update(offset: o, minOffset: min, now: now); now += 0.05 }
    }

    func testScrollingDownHidesAndScrollingUpShows() {
        var v = BarVisibility()
        run(&v, [-100, -100, 0, 40, 80])
        XCTAssertTrue(v.hidden)
        run(&v, [90, 80, 60], t: 12)
        XCTAssertFalse(v.hidden, "16 points up is enough")
    }

    func testSmallMovesAndJitterDoNothing() {
        var v = BarVisibility()
        run(&v, [200, 210, 205, 212, 208, 215])
        XCTAssertFalse(v.hidden)
    }

    func testTopOfThePageAlwaysShowsTheBars() {
        var v = BarVisibility()
        run(&v, [-100, 100, 200, 300])
        XCTAssertTrue(v.hidden)
        run(&v, [-100], t: 12)
        XCTAssertFalse(v.hidden)
        run(&v, [-90], t: 14)                // within the top zone
        XCTAssertFalse(v.hidden)
    }

    func testTheRelayoutRightAfterAChangeIsIgnored() {
        var v = BarVisibility()
        run(&v, [-100, 100, 200, 300], t: 10)
        XCTAssertTrue(v.hidden)
        // the viewport grew and the offset jumped back by 120: not a user scroll within the settle window
        v.update(offset: 180, minOffset: -100, now: 10.3)
        XCTAssertTrue(v.hidden)
        run(&v, [180, 150, 120], t: 11)
        XCTAssertFalse(v.hidden)
    }

    func testScrollsThatAreNotTheFingerNeverHideTheBars() {
        var v = BarVisibility()
        for (i, o) in [-100.0, 100, 300, 500, 700].enumerated() { v.update(offset: o, minOffset: -100, now: 10 + Double(i) * 0.1, userDriven: false) }
        XCTAssertFalse(v.hidden, "page-driven scrolling (anchors, scripts, relayout) does not hide the bars")
        run(&v, [700, 740, 780], t: 12)
        XCTAssertTrue(v.hidden, "the finger still does, counting from where the page now is")
        v.update(offset: -100, minOffset: -100, now: 14, userDriven: false)
        XCTAssertFalse(v.hidden, "reaching the top by any means shows them")
    }

    func testRevealAndResetAndDirectionChange() {
        var v = BarVisibility()
        run(&v, [-100, 100, 200, 300])
        XCTAssertTrue(v.hidden)
        v.reveal(now: 12)
        XCTAssertFalse(v.hidden)
        v.reset()
        XCTAssertFalse(v.hidden)
        run(&v, [500, 520, 510, 530, 520, 540], t: 20)       // down 20, up 10, down 20 ...: never 28 in one direction
        XCTAssertFalse(v.hidden)
    }
}
