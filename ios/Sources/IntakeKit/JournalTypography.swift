#if canImport(UIKit)
  import UIKit

  /// The text view's real fonts are the source of truth for both UIKit actions
  /// and persistence. No private attributed-string marker has to survive typing.
  @MainActor public enum JournalTypography {
    private static func font(_ flags: Int, traits: UITraitCollection? = nil) -> UIFont {
      let base = UIFont.preferredFont(
        forTextStyle: flags & 2 == 0 ? .body : .title2, compatibleWith: traits)
      guard flags & 1 != 0, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold)
      else { return base }
      return UIFont(descriptor: descriptor, size: 0)
    }

    private static func flags(_ value: Any?, traits: UITraitCollection?) -> Int {
      guard let f = value as? UIFont else { return 0 }
      let bold = f.fontDescriptor.symbolicTraits.contains(.traitBold)
      let style = f.fontDescriptor.object(forKey: .textStyle) as? String
      let title = font(bold ? 3 : 2, traits: traits)
      let titleStyle = title.fontDescriptor.object(forKey: .textStyle) as? String
      let heading = (titleStyle != nil && style == titleStyle) || f.pointSize == title.pointSize
      return (bold ? 1 : 0) | (heading ? 2 : 0)
    }

    public static func configure(_ view: UITextView) {
      view.allowsEditingTextAttributes = true
      view.adjustsFontForContentSizeCategory = true
      view.font = font(0, traits: view.traitCollection)
      view.textColor = .label
      #if !targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
          let configuration = UITextFormattingViewController.Configuration(groups: [
            .init(components: [.init(componentKey: .formattingStyles, preferredSize: .regular)])
          ])
          configuration.formattingStyles = [
            .init(styleKey: "body", title: "Body", attributes: [.font: font(0)]),
            .init(styleKey: "bold", title: "Bold", attributes: [.font: font(1)]),
            .init(styleKey: "heading", title: "Heading", attributes: [.font: font(2)]),
            .init(styleKey: "boldHeading", title: "Bold Heading", attributes: [.font: font(3)]),
          ]
          view.textFormattingConfiguration = configuration
        }
      #endif
    }

    public static func text(for row: Record?) -> NSAttributedString {
      let text = NSMutableAttributedString(
        string: row?.text("note") ?? "",
        attributes: [.font: font(0), .foregroundColor: UIColor.label])
      if let row {
        for span in (try? DayStyle.spans(in: row)) ?? [] {
          text.addAttribute(.font, value: font(span.flags), range: span.range)
        }
      }
      return text
    }

    public static func selectedStyle(in view: UITextView) -> Int {
      let range = view.selectedRange
      let value =
        range.length > 0 && range.location < view.textStorage.length
        ? view.textStorage.attribute(.font, at: range.location, effectiveRange: nil)
        : view.typingAttributes[.font]
      return flags(value, traits: view.traitCollection)
    }

    public static func setHeading(_ enabled: Bool, in view: UITextView) {
      let traits = view.traitCollection
      func convert(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = attributes
        result[.font] = font(
          (flags(attributes[.font], traits: traits) & 1) | (enabled ? 2 : 0), traits: traits)
        return result
      }
      if view.selectedRange.length == 0 {
        view.typingAttributes = convert(view.typingAttributes)
      } else {
        view.updateTextAttributes(conversionHandler: convert)
      }
    }

    public static func runs(in text: NSAttributedString, traits: UITraitCollection? = nil)
      -> [DayStyle]
    {
      var result: [DayStyle] = []
      text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) {
        value, range, _ in
        let style = flags(value, traits: traits)
        guard style != 0 else { return }
        if let last = result.last, last.flags == style, NSMaxRange(last.range) == range.location {
          result[result.count - 1] = DayStyle(range: NSUnionRange(last.range, range), flags: style)
        } else {
          result.append(DayStyle(range: range, flags: style))
        }
      }
      return result
    }
  }
#endif
