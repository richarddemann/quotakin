import CoreGraphics
import Testing
@testable import UsageBar

@Test
func centeredFrameKeepsWindowInsideVisibleScreen() {
    let frame = WindowFocus.centeredFrame(
        windowSize: CGSize(width: 900, height: 700),
        visibleFrame: CGRect(x: 100, y: 50, width: 800, height: 600)
    )

    #expect(frame.width == 720)
    #expect(frame.height == 540)
    #expect(frame.minX >= 100)
    #expect(frame.maxX <= 900)
    #expect(frame.minY >= 50)
    #expect(frame.maxY <= 650)
}
