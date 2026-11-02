import SwiftUI

public struct PhotoPrivacyNotice: View {
    private let proceed: () -> Void
    private let cancel: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(proceed: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.proceed = proceed
        self.cancel = cancel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Photos are public", bundle: .module)
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "Photos you choose are uploaded to GistPad's public image storage. Anyone with an image link can view them, even in a secret gist. Location metadata is removed, but visible details remain.",
                        bundle: .module
                    )
                    .font(.body)
                }
                .frame(maxWidth: 540, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(24)
            }
            .navigationTitle(String(localized: "Photos", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel, action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Continue", bundle: .module), action: proceed)
                }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
