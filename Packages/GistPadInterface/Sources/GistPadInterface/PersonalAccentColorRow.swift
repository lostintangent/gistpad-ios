#if os(iOS)
import GistPadAppearance
import SwiftUI

public struct PersonalAccentColorRow: View {
    private let savedHex: String?
    private let save: @MainActor (String) async throws -> Void
    @State private var picked: RGBColor?
    @State private var error: String?
    @Environment(\.self) private var environment

    public init(savedHex: String?, save: @escaping @MainActor (String) async throws -> Void) {
        self.savedHex = savedHex
        self.save = save
    }

    private var saved: RGBColor { PersonalAccent(savedHex: savedHex).color }

    public var body: some View {
        ColorPicker(
            String(localized: "Accent Color", bundle: .module),
            selection: Binding(
                get: { (picked ?? saved).color },
                set: { picked = RGBColor($0.resolve(in: environment)) }),
            supportsOpacity: false
        )
        .accessibilityIdentifier("settings-accent-color")
        // The picker reports every drag step, so save once the color settles.
        .task(id: picked) {
            guard let picked, picked != saved else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                try await save(picked.hex)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
        if let error {
            Text(verbatim: error)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("settings-accent-error")
        }
    }
}

extension View {
    public func personalAccent(savedHex: String?) -> some View {
        environment(\.personalAccent, PersonalAccent(savedHex: savedHex))
    }
}
#endif
