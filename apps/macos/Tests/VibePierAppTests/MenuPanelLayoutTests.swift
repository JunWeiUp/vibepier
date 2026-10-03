import AppKit
import SwiftUI
import XCTest

@testable import VibePierApp

@MainActor
final class MenuPanelLayoutTests: XCTestCase {
    func testShortPanelHasContentHeightOnFirstLayout() {
        let view = NSHostingView(
            rootView: MenuPanelLayout(maximumHeight: 760) {
                Color.clear.frame(height: 320)
            })
        XCTAssertEqual(view.fittingSize.width, 340, accuracy: 1)
        XCTAssertEqual(view.fittingSize.height, 320, accuracy: 1)
    }

    func testLongPanelFitsScreenOnFirstLayout() {
        for limit: CGFloat in [400, 760] {
            let view = NSHostingView(
                rootView: MenuPanelLayout(maximumHeight: limit) {
                    Color.clear.frame(height: 1100)
                })
            XCTAssertEqual(view.fittingSize.width, 340, accuracy: 1)
            XCTAssertEqual(view.fittingSize.height, limit, accuracy: 1)
        }
    }
}
