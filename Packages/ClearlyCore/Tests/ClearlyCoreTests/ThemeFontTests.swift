import XCTest
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
@testable import ClearlyCore

final class ThemeFontTests: XCTestCase {
    func testEditorFontTokensUsePreferredFamilies() {
        XCTAssertEqual(Theme.editorFont.fontName, "HelveticaNeue")
        XCTAssertEqual(Theme.editorBoldFont.fontName, "HelveticaNeue-Bold")
        if PlatformFont(name: "JetBrainsMono-Regular", size: Theme.editorFontSize) != nil {
            XCTAssertEqual(Theme.editorCodeFont.fontName, "JetBrainsMono-Regular")
        } else {
            XCTAssertFalse(Theme.editorCodeFont.fontName.isEmpty)
        }
    }
}
