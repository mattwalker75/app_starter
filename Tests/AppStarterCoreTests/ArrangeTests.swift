import XCTest
@testable import AppStarterCore

/// Drag and drop in a bundle: every kind of move, and the ones that must change nothing.
final class ArrangeTests: XCTestCase {
    // A: one-app step · G: sub-bundle with g1, g2 · B: one-app step · H: sub-bundle with h1
    let a = AppItem(name: "A"), b = AppItem(name: "B"), g1 = AppItem(name: "g1"), g2 = AppItem(name: "g2"), h1 = AppItem(name: "h1")
    var sA: Step!, sG: Step!, sB: Step!, sH: Step!, bundle: AppBundle!

    override func setUp() {
        sA = Step(app: a); sG = Step(group: "G", apps: [g1, g2]); sB = Step(app: b); sH = Step(group: "H", apps: [h1])
        bundle = AppBundle(name: "X", steps: [sA, sG, sB, sH])
    }

    private func layout(_ x: AppBundle?) -> String {
        guard let x else { return "nil" }
        return x.steps.map { $0.isGroup ? "\($0.name)[\($0.apps.map(\.name).joined(separator: ","))]" : $0.apps.first!.name }.joined(separator: " ")
    }

    func testTheStartingLayout() { XCTAssertEqual(layout(bundle), "A G[g1,g2] B H[h1]") }

    func testMovingAStepDownAndUp() {
        XCTAssertEqual(layout(bundle.moving(.step(sA.id), to: .gap(3))), "G[g1,g2] B A H[h1]")
        XCTAssertEqual(layout(bundle.moving(.step(sH.id), to: .gap(0))), "H[h1] A G[g1,g2] B")
        XCTAssertEqual(layout(bundle.moving(.step(sG.id), to: .gap(4))), "A B H[h1] G[g1,g2]", "a whole sub-bundle moves too")
    }

    func testDroppingNextToItselfChangesNothing() {
        XCTAssertNil(bundle.moving(.step(sB.id), to: .gap(2)))
        XCTAssertNil(bundle.moving(.step(sB.id), to: .gap(3)))
        XCTAssertNil(bundle.moving(.app(b.id), to: .gap(2)))
    }

    func testDraggingTheAppOfAOneAppStepMovesItsStepAndKeepsItsId() {
        let moved = bundle.moving(.app(a.id), to: .gap(4))
        XCTAssertEqual(layout(moved), "G[g1,g2] B H[h1] A")
        XCTAssertEqual(moved?.steps.last?.id, sA.id)
    }

    func testAnAppComesOutOfASubBundleIntoAStepOfItsOwn() {
        XCTAssertEqual(layout(bundle.moving(.app(g2.id), to: .gap(0))), "g2 A G[g1] B H[h1]")
        XCTAssertEqual(layout(bundle.moving(.app(h1.id), to: .gap(4))), "A G[g1,g2] B H[] h1", "an emptied sub-bundle stays")
    }

    func testAnAppGoesIntoASubBundleAtTheEndOrBeforeAnother() {
        XCTAssertEqual(layout(bundle.moving(.app(a.id), to: .intoGroup(sG.id, before: nil))), "G[g1,g2,A] B H[h1]")
        XCTAssertEqual(layout(bundle.moving(.app(b.id), to: .intoGroup(sG.id, before: g2.id))), "A G[g1,B,g2] H[h1]")
        XCTAssertEqual(layout(bundle.moving(.step(sB.id), to: .intoGroup(sH.id, before: nil))), "A G[g1,g2] H[h1,B]", "a one-app step dropped on a sub-bundle")
    }

    func testAnAppMovesFromOneSubBundleToAnotherAndWithinOne() {
        XCTAssertEqual(layout(bundle.moving(.app(g1.id), to: .intoGroup(sH.id, before: h1.id))), "A G[g2] B H[g1,h1]")
        XCTAssertEqual(layout(bundle.moving(.app(g2.id), to: .intoGroup(sG.id, before: g1.id))), "A G[g2,g1] B H[h1]")
        XCTAssertNil(bundle.moving(.app(g2.id), to: .intoGroup(sG.id, before: nil)), "already last in it")
    }

    func testASubBundleCannotGoInsideAnother() {
        XCTAssertNil(bundle.moving(.step(sG.id), to: .intoGroup(sH.id, before: nil)))
    }

    func testAStepThatGoesIntoASubBundleLeavesTheCustomStopOrder() {
        var x: AppBundle = bundle
        x.stopOrder = [sB.id, sA.id, sG.id, sH.id]
        let moved = x.moving(.app(a.id), to: .intoGroup(sH.id, before: nil))
        XCTAssertEqual(moved?.stopOrder, [sB.id, sG.id, sH.id])
    }

    func testTheDragTokenRoundTrips() {
        XCTAssertEqual(DragItem(token: DragItem.app(a.id).token), .app(a.id))
        XCTAssertEqual(DragItem(token: DragItem.step(sG.id).token), .step(sG.id))
        XCTAssertNil(DragItem(token: "something else"))
    }
}
