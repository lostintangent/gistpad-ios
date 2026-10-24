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
      SourceTextView(
        session: session,
        actions: SourceToolbarActions(
          format: format, link: beginLink, indent: indent, find: find,
          photo: insertPhoto, photoPrivacy: photoPrivacy,
          dismiss: { session.textView.resignFirstResponder() }),
        configuration: SourceToolbarConfiguration(
          canFormat: session.canFormat, canFind: !session.writingToolsActive,
          canInsertPhoto: canInsertPhoto, hasPhoto: insertPhoto != nil,
          hasPhotoPrivacy: photoPrivacy != nil)
      )
      .id(session.viewIdentity)
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
    let actions: SourceToolbarActions
    let configuration: SourceToolbarConfiguration

    func makeCoordinator() -> SourceToolbarCoordinator {
      SourceToolbarCoordinator(actions: actions)
    }

    func makeUIView(context: Context) -> UITextView {
      context.coordinator.update(actions: actions, configuration: configuration)
      session.textView.inputAccessoryView = context.coordinator.toolbar
      return session.textView
    }

    func updateUIView(_ view: UITextView, context: Context) {
      context.coordinator.update(actions: actions, configuration: configuration)
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
