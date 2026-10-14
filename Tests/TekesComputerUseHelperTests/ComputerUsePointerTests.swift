import AppKit
import Testing

@testable import TekesComputerUseHelper

struct ComputerUsePointerTests {
  @Test @MainActor
  func convertsGlobalAXCoordinatesAcrossDisplays() {
    // AX/CG coordinates use the primary display's top-left, even on other displays.
    #expect(ComputerUsePointer.appKitPoint(CGPoint(x: 0, y: 0), primaryHeight: 900)
      == CGPoint(x: 0, y: 900))
    #expect(ComputerUsePointer.appKitPoint(CGPoint(x: -500, y: 200), primaryHeight: 900)
      == CGPoint(x: -500, y: 700))
    #expect(ComputerUsePointer.appKitPoint(CGPoint(x: 200, y: -400), primaryHeight: 900)
      == CGPoint(x: 200, y: 1300))
    #expect(ComputerUsePointer.appKitPoint(CGPoint(x: 200, y: 1200), primaryHeight: 900)
      == CGPoint(x: 200, y: -300))
  }
}
