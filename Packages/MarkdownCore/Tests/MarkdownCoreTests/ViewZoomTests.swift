import Testing
@testable import MarkdownCore

@Test func zoomInAndOutWalkTheSteps() {
    var level = ViewZoom.actualSize
    var seen = [level]
    while ViewZoom.canZoomIn(from: level) { level = ViewZoom.zoomedIn(from: level); seen.append(level) }
    #expect(seen == [100, 110, 125, 150, 175, 200, 250, 300])
    seen = [level]
    while ViewZoom.canZoomOut(from: level) { level = ViewZoom.zoomedOut(from: level); seen.append(level) }
    #expect(seen == [300, 250, 200, 175, 150, 125, 110, 100, 90, 80, 75, 67, 50])
}

@Test func theLevelStopsAtTheEnds() {
    #expect(ViewZoom.zoomedIn(from: 300) == 300 && !ViewZoom.canZoomIn(from: 300))
    #expect(ViewZoom.zoomedOut(from: 50) == 50 && !ViewZoom.canZoomOut(from: 50))
    #expect(ViewZoom.canZoomIn(from: 50) && ViewZoom.canZoomOut(from: 300))
}

@Test func aLevelBetweenStepsMovesToTheNextStepInThatDirection() {
    #expect(ViewZoom.zoomedIn(from: 105) == 110)
    #expect(ViewZoom.zoomedOut(from: 105) == 100)
}

@Test func storedValuesOutsideTheRangeAreClamped() {
    for (stored, want) in [(0, 50), (-30, 50), (49, 50), (5000, 300), (Int.max, 300), (Int.min, 50), (120, 120)] {
        #expect(ViewZoom.clamped(stored) == want, "\(stored)")
    }
    #expect(ViewZoom.zoomedIn(from: 5000) == 300)
    #expect(ViewZoom.zoomedOut(from: -3) == 50)
    #expect(ViewZoom.factor(5000) == 3 && ViewZoom.factor(100) == 1 && ViewZoom.factor(0) == 0.5)
}
