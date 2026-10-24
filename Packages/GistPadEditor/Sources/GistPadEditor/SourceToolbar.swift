#if canImport(UIKit)
  import GistPadInterface
  import UIKit

  @MainActor
  struct SourceToolbarActions {
    let format: @MainActor (MarkdownFormat) -> Void
    let link: @MainActor () -> Void
    let indent: @MainActor (Bool) -> Void
    let find: @MainActor (Bool) -> Void
    let photo: (@MainActor () -> Void)?
    let photoPrivacy: (@MainActor () -> Void)?
    let dismiss: @MainActor () -> Void
  }

  struct SourceToolbarConfiguration: Equatable {
    let canFormat: Bool
    let canFind: Bool
    let canInsertPhoto: Bool
    let hasPhoto: Bool
    let hasPhotoPrivacy: Bool
  }

  @MainActor
  final class SourceToolbarCoordinator: NSObject {
    let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
    private var actions: SourceToolbarActions
    private var configuration: SourceToolbarConfiguration?

    init(actions: SourceToolbarActions) {
      self.actions = actions
      super.init()
      toolbar.autoresizingMask = [.flexibleWidth]
      toolbar.tintColor = UIColor(InterfaceTheme.accent)
      toolbar.accessibilityIdentifier = "editor-keyboard-bar"
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
      photo.attributes = configuration.hasPhoto && configuration.canInsertPhoto ? [] : .disabled
      var photos: [UIMenuElement] = [photo]
      if configuration.hasPhotoPrivacy {
        photos.append(
          action(String(localized: "Photos Are Public", bundle: .module), image: "info.circle") {
            $0.actions.photoPrivacy?()
          })
      }
      insert.append(UIMenu(options: .displayInline, children: photos))
      let find = [
        action(String(localized: "Find", bundle: .module), image: "magnifyingglass") {
          $0.actions.find(false)
        },
        action(
          String(localized: "Find and Replace", bundle: .module),
          image: "arrow.triangle.2.circlepath"
        ) {
          $0.actions.find(true)
        },
      ]
      let style = item("Text Style", image: "textformat", menu: UIMenu(children: headings))
      let bold = command("Bold", image: "bold") { $0.actions.format(.bold) }
      let italic = command("Italic", image: "italic") { $0.actions.format(.italic) }
      let list = item("Lists", image: "list.bullet", menu: UIMenu(children: lists))
      let insertion = item("Insert", image: "plus", menu: UIMenu(children: insert))
      insertion.accessibilityIdentifier = "editor-insert-menu"
      let search = item("Find", image: "magnifyingglass", menu: UIMenu(children: find))
      let dismiss = command("Hide Keyboard", image: "keyboard.chevron.compact.down") {
        $0.actions.dismiss()
      }
      for item in [style, bold, italic, list, insertion] {
        item.isEnabled = configuration.canFormat
      }
      search.isEnabled = configuration.canFind
      toolbar.items = [style, bold, italic, list, insertion, .flexibleSpace(), search, dismiss]
    }

    private func item(
      _ title: String.LocalizationValue, image: String, menu: UIMenu
    ) -> UIBarButtonItem {
      let item = UIBarButtonItem(image: UIImage(systemName: image), menu: menu)
      item.accessibilityLabel = String(localized: title, bundle: .module)
      item.width = 44
      return item
    }

    private func command(
      _ title: String.LocalizationValue, image: String,
      perform: @escaping @MainActor (SourceToolbarCoordinator) -> Void
    ) -> UIBarButtonItem {
      let title = String(localized: title, bundle: .module)
      let item = UIBarButtonItem(primaryAction: action(title, image: image, perform: perform))
      item.accessibilityLabel = title
      item.width = 44
      return item
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
