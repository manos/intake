#if canImport(UIKit)
  import UIKit
  import XCTest
  @testable import IntakeKit

  @MainActor final class JournalTypographyTests: XCTestCase {
    func testNativeBoldSelectionIsVisibleAndSurvivesReopening() throws {
      let view = UITextView()
      JournalTypography.configure(view)
      view.insertText("a🌿bc")
      view.selectedRange = NSRange(location: 1, length: 2)
      view.toggleBoldface(nil)
      XCTAssertTrue(
        (view.textStorage.attribute(.font, at: 1, effectiveRange: nil) as? UIFont)?.fontDescriptor
          .symbolicTraits.contains(.traitBold) == true)
      let runs = JournalTypography.runs(in: view.attributedText)
      XCTAssertEqual(runs, [DayStyle(range: view.selectedRange, flags: 1)])
      let row = Record(
        .day, data: ["note": .string(view.text), "styles": .array(runs.map(\.wire))])
      let reopened = JournalTypography.text(for: row)
      XCTAssertEqual(JournalTypography.runs(in: reopened), runs)
      XCTAssertFalse(
        (reopened.attribute(.font, at: 3, effectiveRange: nil) as! UIFont).fontDescriptor
          .symbolicTraits.contains(.traitBold))
    }

    func testBoldAndHeadingApplyToSubsequentTypingAndCanBeTurnedOff() {
      let view = UITextView()
      JournalTypography.configure(view)
      XCTAssertTrue(view.text.isEmpty)
      JournalTypography.setHeading(true, in: view)
      view.toggleBoldface(nil)
      view.insertText("Title")
      view.toggleBoldface(nil)
      JournalTypography.setHeading(false, in: view)
      view.insertText(" body")
      XCTAssertEqual(
        JournalTypography.runs(in: view.attributedText),
        [DayStyle(range: NSRange(location: 0, length: 5), flags: 3)])
    }

    func testChangingSizePreservesMixedBoldSelection() {
      let view = UITextView()
      JournalTypography.configure(view)
      view.insertText("abcd")
      view.selectedRange = NSRange(location: 1, length: 2)
      view.toggleBoldface(nil)
      view.selectedRange = NSRange(location: 0, length: 4)
      JournalTypography.setHeading(true, in: view)
      XCTAssertEqual(JournalTypography.runs(in: view.attributedText).map(\.flags), [2, 3, 2])
      XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 4))
    }
  }
#endif
