import GistPadEditor
import GistPadInterface
import Observation
import SwiftUI

@MainActor
@Observable
final class WorkspaceState {
  var editing = LaunchArguments.captureScreen == "editor"
  var focus = LaunchArguments.captureScreen == "focus"
}

struct NotebookWorkspace: View {
  let session: DocumentSession
  @State var state = WorkspaceState()
  @State private var selection: String? = "phase-zero-editor"
  @State private var compactColumn: NavigationSplitViewColumn = .detail

  var body: some View {
    Group {
      if state.focus {
        NavigationStack {
          focusContents
            .navigationTitle("Focus")
            .toolbar { workspaceToolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { diagnostics }
        }
      } else {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
          library
        } detail: {
          NavigationStack {
            documentPages
              .navigationTitle("The shape of a notebook")
              .navigationBarTitleDisplayMode(.inline)
              .toolbar { workspaceToolbar }
              .safeAreaInset(edge: .bottom, spacing: 0) { diagnostics }
          }
        }
        .navigationSplitViewStyle(.balanced)
      }
    }
    .tint(InterfaceTheme.accent)
  }

  private var source: some View {
    MarkdownEditorView(session: session)
  }

  private var focusContents: some View {
    ArrangementView {
      source
    } secondary: {
      preview
    }
    .arrangementViewStyle(.split)
  }

  private var documentPages: some View {
    ZStack {
      source
        .opacity(state.editing ? 1 : 0)
        .allowsHitTesting(state.editing)
        .accessibilityHidden(!state.editing)
      preview
        .opacity(state.editing ? 0 : 1)
        .allowsHitTesting(!state.editing)
        .accessibilityHidden(state.editing)
    }
  }

  @ToolbarContentBuilder
  private var workspaceToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      if !state.focus {
        Button {
          state.editing.toggle()
        } label: {
          if state.editing {
            Label("Read", systemImage: "doc.richtext")
          } else {
            Label("Edit", systemImage: "square.and.pencil")
          }
        }
        .accessibilityIdentifier("toggle-edit")
      }
      Button {
        state.focus.toggle()
      } label: {
        if state.focus {
          Label("Library", systemImage: "sidebar.left")
        } else {
          Label("Focus", systemImage: "rectangle.split.2x1")
        }
      }
      .accessibilityIdentifier("toggle-focus")
    }
    ToolbarItem(placement: .secondaryAction) {
      Button("Find and Replace", systemImage: "magnifyingglass") {
        state.editing = true
        session.presentFind(replacing: true)
      }
    }
  }

  private var library: some View {
    List(selection: $selection) {
      Section {
        Label("Today", systemImage: "sun.max")
          .foregroundStyle(.secondary)
          .accessibilityHint("Daily notes are not connected in this editor spike")
      }
      Section("Synthetic notes") {
        NavigationLink(value: session.documentID) {
          VStack(alignment: .leading, spacing: 6) {
            Text("The shape of a notebook")
              .font(.headline)
            Text("Unicode, composition & continuity")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 6)
        }
      }
      Section {
        Label("No account connected", systemImage: "person.crop.circle")
          .foregroundStyle(.secondary)
      } footer: {
        Text("Phase 0 uses a synthetic note. Your GitHub account is untouched.")
      }
    }
    .navigationTitle("GistPad")
    .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 360)
  }

  private var preview: some View {
    SessionPreview(session: session)
  }

  private var diagnostics: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 4) {
        Text("Editor \(session.viewIdentity.uuidString.prefix(8))")
          .accessibilityIdentifier("editor-identity")
        Text("Generation \(session.generation) · UTF-16 \(session.text.utf16.count)")
        Text("Selection \(session.selection.location):\(session.selection.length)")
        Text(session.isComposing ? "Composing" : "No marked text")
      }
      .font(.caption.monospaced())
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8)
    } label: {
      Label("Phase 0 · Changes are in memory only", systemImage: "hammer")
        .font(.caption)
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.bar)
  }

}
