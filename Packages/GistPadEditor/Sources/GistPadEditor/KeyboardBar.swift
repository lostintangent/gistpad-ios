#if canImport(UIKit)
  import UIKit

  @MainActor
  struct KeyboardBarActions {
    let format: @MainActor (Format) -> Void
    let link: @MainActor () -> Void
    let indent: @MainActor (Bool) -> Void
    let image: (@MainActor () -> Void)?
    let intelligence: (@MainActor () -> Void)?
    let dismiss: @MainActor () -> Void
  }

  struct KeyboardBarConfiguration: Equatable {
    let canFormat: Bool
    let canInsertImage: Bool
    let canUseIntelligence: Bool
  }

  /// The glass capsule above the keyboard. Its buttons call the latest actions SwiftUI passed in.
  /// It centers over the editor's column rather than the keyboard, so an open sidebar doesn't push it off the note.
  @MainActor
  final class KeyboardBar: UIView {
    let buttons = UIStackView()
    let glass: UIVisualEffectView
    weak var textView: UIView?
    private let column = UILayoutGuide()
    private lazy var columnLeft = column.leftAnchor.constraint(equalTo: leftAnchor)
    private lazy var columnRight = column.rightAnchor.constraint(equalTo: rightAnchor)
    private var actions: KeyboardBarActions
    private var configuration: KeyboardBarConfiguration?

    override var intrinsicContentSize: CGSize {
      CGSize(width: UIView.noIntrinsicMetric, height: 72)
    }

    init(actions: KeyboardBarActions) {
      self.actions = actions
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = true
      glass = UIVisualEffectView(effect: effect)
      super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 72))
      autoresizingMask = [.flexibleWidth]
      backgroundColor = .clear
      tintColor = .label
      accessibilityIdentifier = "editor-keyboard-bar"
      glass.cornerConfiguration = .capsule()
      glass.translatesAutoresizingMaskIntoConstraints = false
      addSubview(glass)
      buttons.axis = .horizontal
      buttons.distribution = .fillEqually
      buttons.translatesAutoresizingMaskIntoConstraints = false
      glass.contentView.addSubview(buttons)
      addLayoutGuide(column)
      let preferredWidth = glass.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32)
      preferredWidth.priority = .defaultHigh
      // A column too narrow for the buttons lets the capsule overhang it, never the screen.
      let inColumn = [
        glass.centerXAnchor.constraint(equalTo: column.centerXAnchor),
        glass.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor, constant: 16),
        glass.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor, constant: -16),
      ]
      for constraint in inColumn { constraint.priority = .required - 1 }
      NSLayoutConstraint.activate(inColumn + [
        columnLeft, columnRight,
        column.topAnchor.constraint(equalTo: topAnchor),
        column.bottomAnchor.constraint(equalTo: bottomAnchor),
        glass.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
        glass.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        glass.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        preferredWidth,
        glass.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        buttons.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
        buttons.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
        buttons.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
        buttons.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
      ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(actions:)") }

    override func layoutSubviews() {
      var left: CGFloat = 0
      var right = bounds.width
      if let textView, textView.window != nil, window != nil {
        let frame = textView.convert(textView.bounds, to: self)
        if frame.maxX > 0, frame.minX < bounds.width {
          left = max(frame.minX, 0)
          right = min(frame.maxX, bounds.width)
        }
      }
      columnLeft.constant = left
      columnRight.constant = right - bounds.width
      super.layoutSubviews()
    }

    func update(actions: KeyboardBarActions, configuration: KeyboardBarConfiguration) {
      self.actions = actions
      guard self.configuration != configuration else { return }
      self.configuration = configuration
      var headings = [
        action(String(localized: "Body", bundle: .module)) { $0.actions.format(.heading(0)) }
      ]
      headings += (1...6).map { level in
        action(String(localized: "Heading \(level)", bundle: .module)) {
          $0.actions.format(.heading(level))
        }
      }
      let lists = [
        action(String(localized: "Bulleted List", bundle: .module), image: "list.bullet") {
          $0.actions.format(.bulletList)
        },
        action(String(localized: "Numbered List", bundle: .module), image: "list.number") {
          $0.actions.format(.numberedList)
        },
        action(String(localized: "Checklist", bundle: .module), image: "checklist") {
          $0.actions.format(.checklist)
        },
        action(String(localized: "Increase Indent", bundle: .module), image: "increase.indent") {
          $0.actions.indent(false)
        },
        action(String(localized: "Decrease Indent", bundle: .module), image: "decrease.indent") {
          $0.actions.indent(true)
        },
      ]
      var insert: [UIMenuElement] = [
        action(String(localized: "Link…", bundle: .module), image: "link") { $0.actions.link() },
        action(
          String(localized: "Inline Code", bundle: .module),
          image: "chevron.left.forwardslash.chevron.right"
        ) {
          $0.actions.format(.inlineCode)
        },
        action(String(localized: "Code Block", bundle: .module), image: "curlybraces.square") {
          $0.actions.format(.codeBlock)
        },
        action(String(localized: "Quote", bundle: .module), image: "text.quote") {
          $0.actions.format(.quote)
        },
      ]
      let image = action(String(localized: "Image…", bundle: .module), image: "photo") {
        $0.actions.image?()
      }
      image.attributes = configuration.canInsertImage ? [] : .disabled
      insert.append(UIMenu(options: .displayInline, children: [image]))
      let emphasis = [
        action(String(localized: "Bold", bundle: .module), image: "bold") {
          $0.actions.format(.bold)
        },
        action(String(localized: "Italic", bundle: .module), image: "italic") {
          $0.actions.format(.italic)
        },
      ]
      let style = item(
        "Text Style", image: "textformat",
        menu: UIMenu(children: [
          UIMenu(options: .displayInline, children: emphasis),
          UIMenu(options: .displayInline, children: headings),
        ]))
      let list = item("Lists", image: "list.bullet", menu: UIMenu(children: lists))
      let insertion = item("Insert", image: "plus", menu: UIMenu(children: insert))
      insertion.accessibilityIdentifier = "editor-insert-menu"
      let intelligence = command("Intelligence", image: "sparkles") {
        $0.actions.intelligence?()
      }
      intelligence.accessibilityIdentifier = "editor-intelligence"
      intelligence.isEnabled = configuration.canUseIntelligence
      let dismiss = command("Hide Keyboard", image: "keyboard.chevron.compact.down") {
        $0.actions.dismiss()
      }
      for item in [style, list, insertion] {
        item.isEnabled = configuration.canFormat
      }
      for view in buttons.arrangedSubviews { view.removeFromSuperview() }
      for item in [style, list, insertion, intelligence, dismiss] {
        buttons.addArrangedSubview(item)
        item.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      }
    }

    private func item(
      _ title: String.LocalizationValue, image: String, menu: UIMenu
    ) -> UIButton {
      let button = UIButton(type: .system)
      button.menu = menu
      button.showsMenuAsPrimaryAction = true
      style(button, title: String(localized: title, bundle: .module), image: image)
      return button
    }

    private func command(
      _ title: String.LocalizationValue, image: String,
      perform: @escaping @MainActor (KeyboardBar) -> Void
    ) -> UIButton {
      let title = String(localized: title, bundle: .module)
      let button = UIButton(type: .system)
      button.addAction(action(title, image: image, perform: perform), for: .primaryActionTriggered)
      style(button, title: title, image: image)
      return button
    }

    private func style(_ button: UIButton, title: String, image: String) {
      var configuration = UIButton.Configuration.plain()
      configuration.image = UIImage(systemName: image)
      configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
        pointSize: 18, weight: .medium)
      configuration.contentInsets = .zero
      button.configuration = configuration
      button.accessibilityLabel = title
    }

    private func action(
      _ title: String, image: String? = nil,
      perform: @escaping @MainActor (KeyboardBar) -> Void
    ) -> UIAction {
      UIAction(title: title, image: image.flatMap { UIImage(systemName: $0) }) { [weak self] _ in
        guard let self else { return }
        perform(self)
      }
    }

  }
#endif
