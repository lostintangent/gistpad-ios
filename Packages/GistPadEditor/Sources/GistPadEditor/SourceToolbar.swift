#if canImport(UIKit)
  import GistPadInterface
  import UIKit

  @MainActor
  struct SourceToolbarActions {
    let format: @MainActor (MarkdownFormat) -> Void
    let link: @MainActor () -> Void
    let indent: @MainActor (Bool) -> Void
    let photo: (@MainActor () -> Void)?
    var intelligence: (@MainActor () -> Void)? = nil
    let dismiss: @MainActor () -> Void
  }

  struct SourceToolbarConfiguration: Equatable {
    let canFormat: Bool
    let canInsertPhoto: Bool
    let hasPhoto: Bool
    var canUseIntelligence = true
    var hasIntelligence = false
  }

  @MainActor
  final class SourceAccessoryView: UIView {
    let buttons = UIStackView()
    let glass: UIVisualEffectView

    override var intrinsicContentSize: CGSize {
      CGSize(width: UIView.noIntrinsicMetric, height: 72)
    }

    init() {
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
      let preferredWidth = glass.widthAnchor.constraint(equalTo: widthAnchor, constant: -32)
      preferredWidth.priority = .defaultHigh
      NSLayoutConstraint.activate([
        glass.centerXAnchor.constraint(equalTo: centerXAnchor),
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
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func setButtons(_ items: [UIButton]) {
      for view in buttons.arrangedSubviews {
        buttons.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
      for item in items {
        buttons.addArrangedSubview(item)
        item.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      }
    }
  }

  @MainActor
  final class SourceToolbarCoordinator: NSObject {
    let toolbar = SourceAccessoryView()
    private var actions: SourceToolbarActions
    private var configuration: SourceToolbarConfiguration?

    init(actions: SourceToolbarActions) {
      self.actions = actions
      super.init()
    }

    func update(actions: SourceToolbarActions, configuration: SourceToolbarConfiguration) {
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
      let photo = action(String(localized: "Photo", bundle: .module), image: "photo") {
        $0.actions.photo?()
      }
      photo.subtitle = String(localized: "Public, even in a secret gist", bundle: .module)
      photo.attributes = configuration.hasPhoto && configuration.canInsertPhoto ? [] : .disabled
      insert.append(UIMenu(options: .displayInline, children: [photo]))
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
      intelligence.isEnabled = configuration.hasIntelligence && configuration.canUseIntelligence
      let dismiss = command("Hide Keyboard", image: "keyboard.chevron.compact.down") {
        $0.actions.dismiss()
      }
      for item in [style, list, insertion] {
        item.isEnabled = configuration.canFormat
      }
      toolbar.setButtons([style, list, insertion, intelligence, dismiss])
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
      perform: @escaping @MainActor (SourceToolbarCoordinator) -> Void
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
      perform: @escaping @MainActor (SourceToolbarCoordinator) -> Void
    ) -> UIAction {
      UIAction(title: title, image: image.flatMap { UIImage(systemName: $0) }) { [weak self] _ in
        guard let self else { return }
        perform(self)
      }
    }

  }
#endif
