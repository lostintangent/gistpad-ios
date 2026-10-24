import Foundation

public enum PhotoAttachmentAction: Equatable, Sendable {
    case retry, reconnect, insertHere, chooseAnother
}

public enum PhotoAttachmentPhase: Equatable, Sendable {
    case preparing
    case queued
    case waitingForNote
    case uploading
    case checking
    case offline
    case reconnect
    case ready
    case failed(message: String, retryAfter: Date? = nil)
    case localFailure(message: String)
    case preparationFailed(message: String)
}

public struct PhotoAttachment: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var thumbnail: Data?
    public var phase: PhotoAttachmentPhase
    public var action: PhotoAttachmentAction?
    public var actionEnabled: Bool
    public var canRemove: Bool
    public var guidance: String?

    public init(
        id: UUID, thumbnail: Data? = nil, phase: PhotoAttachmentPhase,
        action: PhotoAttachmentAction? = nil, actionEnabled: Bool = true,
        canRemove: Bool = true, guidance: String? = nil
    ) {
        self.id = id
        self.thumbnail = thumbnail
        self.phase = phase
        self.action = action
        self.actionEnabled = actionEnabled
        self.canRemove = canRemove
        self.guidance = guidance
    }

    public func isActionEnabled(at date: Date) -> Bool {
        guard action != nil, actionEnabled else { return false }
        if case .failed(_, let deadline) = phase, let deadline { return deadline <= date }
        return true
    }
}

#if os(iOS)
import SwiftUI

public struct PhotoPrivacyNotice: View {
    private let proceed: (() -> Void)?
    private let cancel: () -> Void

    public init(proceed: (() -> Void)? = nil, cancel: @escaping () -> Void) {
        self.proceed = proceed
        self.cancel = cancel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                Text(
                    "Photos you choose are uploaded to GistPad's public image storage. Anyone with an image link can view them, even in a secret gist. Location metadata is removed, but visible details remain.",
                    bundle: .module
                )
                .font(.body)
                .frame(maxWidth: 540, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(24)
            }
            .navigationTitle(String(localized: "Photos are public", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        proceed == nil ? String(localized: "Done", bundle: .module)
                            : String(localized: "Cancel", bundle: .module),
                        action: cancel
                    )
                }
                if let proceed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Continue", bundle: .module), action: proceed)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

public struct PhotoAttachmentShelf: View {
    private let attachments: [PhotoAttachment]
    private let action: (UUID, PhotoAttachmentAction) -> Void
    private let remove: (UUID) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(
        attachments: [PhotoAttachment],
        action: @escaping (UUID, PhotoAttachmentAction) -> Void,
        remove: @escaping (UUID) -> Void
    ) {
        self.attachments = attachments
        self.action = action
        self.remove = remove
    }

    public var body: some View {
        if !attachments.isEmpty {
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: shelfHeight)
            }
            .frame(maxHeight: shelfHeight)
            .background(Color(uiColor: .systemBackground))
            .scrollEdgeEffectStyle(.soft, for: .all)
            .accessibilityIdentifier("pending-photos")
        }
    }

    private var shelfHeight: CGFloat { typeSize.isAccessibilitySize ? 180 : 128 }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(attachments) { attachment in row(attachment) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ attachment: PhotoAttachment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let data = attachment.thumbnail, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.primary)
                }
            }
            .frame(width: 44, height: 44)
            .clipped()
            .clipShape(.rect(cornerRadius: 6))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Photo", bundle: .module).font(.body.weight(.semibold))
                    Spacer(minLength: 8)
                    if attachment.canRemove {
                        Menu {
                            Button(
                                String(localized: "Remove Pending Photo", bundle: .module),
                                systemImage: "trash", role: .destructive
                            ) { remove(attachment.id) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel(Text("Photo options", bundle: .module))
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    if isBusy(attachment.phase) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
                    Text(status(attachment.phase)).font(.subheadline)
                }
                if let detail = detail(attachment.phase) {
                    Text(detail).font(.subheadline)
                }
                if let guidance = attachment.guidance {
                    Text(guidance).font(.subheadline)
                }
                if let recovery = attachment.action {
                    if case .failed(_, .some) = attachment.phase {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            recoveryButton(recovery, attachment: attachment, date: timeline.date)
                        }
                    } else {
                        recoveryButton(recovery, attachment: attachment, date: .now)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .contain)
    }

    private func status(_ phase: PhotoAttachmentPhase) -> String {
        switch phase {
        case .preparing: String(localized: "Preparing photo...", bundle: .module)
        case .queued: String(localized: "Photo saved on this iPhone", bundle: .module)
        case .waitingForNote: String(localized: "Save this note to GitHub to upload the photo.", bundle: .module)
        case .uploading: String(localized: "Uploading photo...", bundle: .module)
        case .checking: String(localized: "Checking upload...", bundle: .module)
        case .offline: String(localized: "Saved on this iPhone. Waiting for connection.", bundle: .module)
        case .reconnect: String(localized: "Reconnect to upload", bundle: .module)
        case .ready: String(localized: "Photo ready", bundle: .module)
        case .failed: String(localized: "Couldn't upload photo", bundle: .module)
        case .localFailure: String(localized: "Couldn't save this photo on this iPhone", bundle: .module)
        case .preparationFailed: String(localized: "Couldn't prepare this photo.", bundle: .module)
        }
    }

    private func actionTitle(_ action: PhotoAttachmentAction) -> String {
        switch action {
        case .retry: String(localized: "Retry", bundle: .module)
        case .reconnect: String(localized: "Reconnect GitHub", bundle: .module)
        case .insertHere: String(localized: "Insert Here", bundle: .module)
        case .chooseAnother: String(localized: "Choose Another Photo", bundle: .module)
        }
    }

    private func isBusy(_ phase: PhotoAttachmentPhase) -> Bool {
        switch phase {
        case .preparing, .uploading, .checking: true
        default: false
        }
    }

    private func detail(_ phase: PhotoAttachmentPhase) -> String? {
        switch phase {
        case .failed(let message, _), .localFailure(let message), .preparationFailed(let message): message
        default: nil
        }
    }

    private func recoveryButton(
        _ recovery: PhotoAttachmentAction, attachment: PhotoAttachment, date: Date
    ) -> some View {
        Button(actionTitle(recovery)) { action(attachment.id, recovery) }
            .font(.body)
            .frame(minHeight: 44)
            .disabled(!attachment.isActionEnabled(at: date))
    }
}
#endif
