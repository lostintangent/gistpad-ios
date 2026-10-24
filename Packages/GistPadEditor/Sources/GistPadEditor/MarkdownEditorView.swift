#if canImport(UIKit)
  import SwiftUI
  import UIKit

  public struct MarkdownEditorView: View {
    public let session: DocumentSession
    private let insertPhoto: (@MainActor () -> Void)?
    private let photoPrivacy: (@MainActor () -> Void)?
    private let canInsertPhoto: Bool
    @State private var linkRequest: LinkRequest?
    @State private var actionError: String?

    public init(
      session: DocumentSession,
      insertPhoto: (@MainActor () -> Void)? = nil,
      photoPrivacy: (@MainActor () -> Void)? = nil,
      canInsertPhoto: Bool = false
    ) {
      self.session = session
      self.insertPhoto = insertPhoto
      self.photoPrivacy = photoPrivacy
      self.canInsertPhoto = canInsertPhoto
    }

    public var body: some View {
      SourceTextView(session: session)
        .toolbar {
          if session.isEditing {
            ToolbarItemGroup(placement: .keyboard) {
              controls
            }
          }
        }
        .sheet(
          item: $linkRequest,
          onDismiss: {
            if session.textView.window != nil, session.textView.isEditable {
              session.textView.becomeFirstResponder()
            }
          }
        ) { request in
          LinkEditor(label: request.label) { label, destination in
            guard session.documentID == request.documentID else {
              throw SourceMutation.MutationError.documentMismatch
            }
            if let edit = try MarkdownFormatting.edit(
              .link(label: label, destination: destination), in: request.source,
              selection: request.selection)
            {
              try session.apply(edit, generation: request.generation)
            }
          }
        }
        .alert(
          String(localized: "Couldn't Format Text", bundle: .module),
          isPresented: Binding(
            get: { actionError != nil || session.inputError != nil },
            set: {
              if !$0 {
                actionError = nil
                session.inputError = nil
              }
            })
        ) {
          Button(String(localized: "OK", bundle: .module), role: .cancel) {
            actionError = nil
            session.inputError = nil
          }
        } message: {
          Text(actionError ?? session.inputError ?? "")
        }
    }

    private var controls: some View {
      HStack(spacing: 0) {
        Menu {
          Button(String(localized: "Body", bundle: .module)) { format(.heading(0)) }
          ForEach(1...6, id: \.self) { level in
            Button(String(localized: "Heading \(level)", bundle: .module)) {
              format(.heading(level))
            }
          }
        } label: {
          Label(String(localized: "Text Style", bundle: .module), systemImage: "textformat")
            .labelStyle(.iconOnly)
        }
        .frame(minWidth: 44, minHeight: 44)
        .disabled(!session.canFormat)
        Button(String(localized: "Bold", bundle: .module), systemImage: "bold") { format(.bold) }
          .labelStyle(.iconOnly)
          .frame(minWidth: 44, minHeight: 44)
          .disabled(!session.canFormat)
        Button(String(localized: "Italic", bundle: .module), systemImage: "italic") {
          format(.italic)
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(!session.canFormat)
        Menu {
          Button(String(localized: "Bulleted List", bundle: .module), systemImage: "list.bullet") {
            format(.bulletList)
          }
          Button(String(localized: "Numbered List", bundle: .module), systemImage: "list.number") {
            format(.numberedList)
          }
          Button(String(localized: "Checklist", bundle: .module), systemImage: "checklist") {
            format(.checklist)
          }
          Divider()
          Button(
            String(localized: "Increase Indent", bundle: .module), systemImage: "increase.indent"
          ) {
            indent(outdent: false)
          }
          .keyboardShortcut("]", modifiers: .command)
          Button(
            String(localized: "Decrease Indent", bundle: .module), systemImage: "decrease.indent"
          ) {
            indent(outdent: true)
          }
          .keyboardShortcut("[", modifiers: .command)
        } label: {
          Label(String(localized: "Lists", bundle: .module), systemImage: "list.bullet")
            .labelStyle(.iconOnly)
        }
        .frame(minWidth: 44, minHeight: 44)
        .disabled(!session.canFormat)
        Menu {
          Button(String(localized: "Link…", bundle: .module), systemImage: "link") { beginLink() }
          Button(
            String(localized: "Inline Code", bundle: .module),
            systemImage: "chevron.left.forwardslash.chevron.right"
          ) {
            format(.inlineCode)
          }
          Button(
            String(localized: "Code Block", bundle: .module), systemImage: "curlybraces.square"
          ) {
            format(.codeBlock)
          }
          Button(String(localized: "Quote", bundle: .module), systemImage: "text.quote") {
            format(.quote)
          }
          Divider()
          Button(String(localized: "Photo", bundle: .module), systemImage: "photo") {
            insertPhoto?()
          }
          .disabled(insertPhoto == nil || !canInsertPhoto)
          if photoPrivacy != nil {
            Button(
              String(localized: "Photos Are Public", bundle: .module), systemImage: "info.circle"
            ) {
              photoPrivacy?()
            }
          }
        } label: {
          Label(String(localized: "Insert", bundle: .module), systemImage: "plus")
            .labelStyle(.iconOnly)
        }
        .accessibilityIdentifier("editor-insert-menu")
        .frame(minWidth: 44, minHeight: 44)
        .disabled(!session.canFormat)
        Menu {
          Button(String(localized: "Find", bundle: .module), systemImage: "magnifyingglass") {
            find(replacing: false)
          }
          .keyboardShortcut("f", modifiers: .command)
          Button(
            String(localized: "Find and Replace", bundle: .module),
            systemImage: "arrow.triangle.2.circlepath"
          ) {
            find(replacing: true)
          }
          .keyboardShortcut("f", modifiers: [.command, .option])
        } label: {
          Label(String(localized: "Find", bundle: .module), systemImage: "magnifyingglass")
            .labelStyle(.iconOnly)
        }
        .frame(minWidth: 44, minHeight: 44)
        .disabled(session.writingToolsActive)
        Spacer(minLength: 0)
        Button(
          String(localized: "Hide Keyboard", bundle: .module),
          systemImage: "keyboard.chevron.compact.down"
        ) {
          session.textView.resignFirstResponder()
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
      }
    }

    private func format(_ command: MarkdownFormat) {
      do {
        if let edit = try MarkdownFormatting.edit(
          command, in: session.text, selection: session.textView.selectedRange)
        {
          try session.apply(edit, generation: session.generation)
        }
      } catch SourceMutation.MutationError.compositionActive {
        actionError = String(
          localized:
            "The source couldn't be formatted. Try again after composition or Writing Tools finishes.",
          bundle: .module)
      } catch {
        actionError = String(
          localized: "The source changed. Select the text again before formatting.", bundle: .module
        )
      }
    }

    private func beginLink() {
      let selection = session.textView.selectedRange
      guard session.canFormat, let range = Range(selection, in: session.text) else {
        actionError = String(
          localized: "Finish the current text edit, then select the link text again.",
          bundle: .module)
        return
      }
      linkRequest = LinkRequest(
        documentID: session.documentID, source: session.text, generation: session.generation,
        selection: selection,
        label: String(session.text[range]))
    }

    private func indent(outdent: Bool) {
      do {
        try session.indent(outdent: outdent)
      } catch {
        actionError = String(
          localized: "Finish the current text edit, then select the lines again.", bundle: .module)
      }
    }

    private func find(replacing: Bool) {
      guard let interaction = session.textView.findInteraction else {
        actionError = String(localized: "Find is unavailable in this editor.", bundle: .module)
        return
      }
      interaction.presentFindNavigator(showingReplace: replacing)
    }
  }

  private struct SourceTextView: UIViewRepresentable {
    let session: DocumentSession
    func makeUIView(context: Context) -> UITextView { session.textView }
    func updateUIView(_ view: UITextView, context: Context) {
      session.updateAppearanceIfNeeded()
    }
  }

  private struct LinkRequest: Identifiable {
    let id = UUID()
    let documentID: String
    let source: String
    let generation: UInt64
    let selection: NSRange
    let label: String
  }

  private struct LinkEditor: View {
    @State var label: String
    @State private var destination = ""
    @State private var error: String?
    @FocusState private var urlFocused: Bool
    let save: @MainActor (String, String) throws -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        Form {
          TextField(String(localized: "Text", bundle: .module), text: $label)
          TextField(String(localized: "URL", bundle: .module), text: $destination)
            .focused($urlFocused)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          if let error { Text(error).foregroundStyle(.red) }
        }
        .defaultFocus($urlFocused, true)
        .navigationTitle(String(localized: "Add Link", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(role: .cancel) { dismiss() }
              .accessibilityLabel(String(localized: "Cancel", bundle: .module))
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(role: .confirm) { insert() }
              .accessibilityLabel(String(localized: "Insert Link", bundle: .module))
              .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
    }

    private func insert() {
      do {
        try save(label, destination)
        dismiss()
      } catch MarkdownFormatting.FormattingError.invalidLink {
        self.error = String(
          localized: "Enter a complete web, email or phone link.", bundle: .module)
      } catch {
        self.error = String(
          localized:
            "The source changed while this sheet was open. Cancel and select the text again.",
          bundle: .module)
      }
    }
  }
#endif
