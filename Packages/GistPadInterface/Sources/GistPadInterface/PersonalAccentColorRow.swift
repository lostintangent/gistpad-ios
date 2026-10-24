#if os(iOS)
import GistPadAppearance
import SwiftUI

public struct PersonalAccentColorRow: View {
    private let savedHex: String?
    private let hasInvalidStoredValue: Bool
    private let save: @MainActor (String) async throws -> Void
    @State private var chosenColor: RGBColor?
    @State private var isSaving = false
    @State private var error: String?

    public init(
        savedHex: String?, hasInvalidStoredValue: Bool = false,
        save: @escaping @MainActor (String) async throws -> Void
    ) {
        self.savedHex = savedHex
        self.hasInvalidStoredValue = hasInvalidStoredValue
        self.save = save
    }

    #if DEBUG
    public func capturePendingColor(_ value: RGBColor) -> Self {
        var row = self
        row._chosenColor = State(initialValue: value)
        return row
    }
    #endif

    private var preference: PersonalAccent { PersonalAccent(savedHex: savedHex) }
    private var selected: RGBColor { chosenColor ?? preference.color }

    public var body: some View {
        ColorPicker(
            String(localized: "Accent Color", bundle: .module),
            selection: Binding(
                get: { Color(uiColor: selected.uiColor) },
                set: { color in
                    guard let rgb = RGBColor(uiColor: UIColor(color)) else {
                        error = String(localized: "Choose an opaque RGB color.", bundle: .module)
                        return
                    }
                    chosenColor = rgb
                    error = nil
                }
            ),
            supportsOpacity: false
        )
        .disabled(isSaving)
        .accessibilityIdentifier("settings-accent-color")
        if preference.isInvalid || hasInvalidStoredValue {
            Label {
                Text("Your saved color couldn't be read. GistPad Sky is in use until you choose a new color.", bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(.footnote)
        }
        if chosenColor != nil, selected != preference.color || preference.isInvalid || hasInvalidStoredValue {
            Button {
                let hex = selected.hex
                isSaving = true
                error = nil
                Task {
                    do {
                        try await save(hex)
                        chosenColor = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                    isSaving = false
                }
            } label: {
                HStack {
                    Text("Save Accent Color", bundle: .module)
                    if isSaving { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isSaving)
            .accessibilityIdentifier("settings-save-accent")
        }
        if let error {
            Text(verbatim: error)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings-accent-error")
        }
    }
}
#endif
