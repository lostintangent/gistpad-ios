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

    var failureExplanation: String? {
        switch self {
        case .failed(let message, _), .localFailure(let message), .preparationFailed(let message): message
        default: nil
        }
    }
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

    public var hasFailure: Bool { phase.failureExplanation != nil }
}

struct PhotoAttachmentSection: Identifiable, Sendable {
    let id: UUID
    private(set) var attachments: [PhotoAttachment]

    var sharedFailureExplanation: String? {
        attachments.count > 1 ? attachments.first?.phase.failureExplanation : nil
    }

    static func grouping(_ attachments: [PhotoAttachment]) -> [Self] {
        var sections: [Self] = []
        var failureSections: [String: Int] = [:]
        for attachment in attachments {
            if let explanation = attachment.phase.failureExplanation {
                if let index = failureSections[explanation] {
                    sections[index].attachments.append(attachment)
                } else {
                    failureSections[explanation] = sections.count
                    sections.append(Self(id: attachment.id, attachments: [attachment]))
                }
            } else if let last = sections.indices.last,
                sections[last].attachments.first?.phase.failureExplanation == nil
            {
                sections[last].attachments.append(attachment)
            } else {
                sections.append(Self(id: attachment.id, attachments: [attachment]))
            }
        }
        return sections
    }
}

#if os(iOS)
import GistPadAppearance
import SwiftUI

public struct PhotoPrivacyNotice: View {
    private let proceed: (() -> Void)?
    private let cancel: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(proceed: (() -> Void)? = nil, cancel: @escaping () -> Void) {
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
                    Button(
                        proceed == nil ? String(localized: "Done", bundle: .module)
                            : String(localized: "Cancel", bundle: .module),
                        action: cancel
                    )
                    .tint(.primary)
                }
                if let proceed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Continue", bundle: .module), action: proceed)
                            .tint(.primary)
                    }
                }
            }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

public struct PhotoAttachmentShelf: View {
    private let attachments: [PhotoAttachment]
    private let details: () -> Void
    private let maximumHeight: CGFloat?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(
        attachments: [PhotoAttachment],
        maximumHeight: CGFloat? = nil,
        details: @escaping () -> Void
    ) {
        self.attachments = attachments
        self.maximumHeight = maximumHeight
        self.details = details
    }

    public var body: some View {
        if !attachments.isEmpty {
            summary
                .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 16))
                .padding(.horizontal, 16)
                .padding(.vertical, verticalPadding)
        }
    }

    private var shelfHeight: CGFloat {
        min(typeSize.isAccessibilitySize ? 180 : 128, max(44, maximumHeight ?? .infinity))
    }

    private var verticalPadding: CGFloat {
        min(8, max(0, (shelfHeight - 44) / 2))
    }

    private var summary: some View {
        PhotoActionButton(
            id: "pending-photos-summary",
            title: attachments.count == 1
                ? String(localized: "1 photo", bundle: .module)
                : String(localized: "\(attachments.count) photos", bundle: .module),
            value: attachments.contains(where: \.hasFailure)
                ? String(localized: "\(attachments.filter(\.hasFailure).count) couldn't upload", bundle: .module)
                : String(localized: "Upload statuses in Details", bundle: .module),
            hint: String(localized: "Show photo details", bundle: .module),
            action: details
        ) {
            ViewThatFits {
                summaryLabel(showsStatus: true, usesPhotoSymbol: false)
                summaryLabel(showsStatus: false, usesPhotoSymbol: false)
                summaryLabel(showsStatus: false, usesPhotoSymbol: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(
                maxWidth: .infinity, minHeight: 44,
                maxHeight: shelfHeight - 2 * verticalPadding, alignment: .leading)
            .contentShape(.rect(cornerRadius: 16))
            .environment(\.dynamicTypeSize, typeSize)
        }
    }

    private func summaryLabel(showsStatus: Bool, usesPhotoSymbol: Bool) -> some View {
        HStack(spacing: 12) {
            if !typeSize.isAccessibilitySize,
               let data = attachments.first?.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            if usesPhotoSymbol {
                Image(systemName: "photo.on.rectangle")
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if usesPhotoSymbol {
                        Text(attachments.count.formatted())
                    } else {
                        photoCount
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                if showsStatus, attachments.contains(where: \.hasFailure) {
                    Text("\(attachments.filter(\.hasFailure).count) couldn't upload", bundle: .module)
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !showsStatus, attachments.contains(where: \.hasFailure) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.forward")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        }
    }

    private var photoCount: Text {
        attachments.count == 1
            ? Text("1 photo", bundle: .module)
            : Text("\(attachments.count) photos", bundle: .module)
    }
}

public struct PhotoAttachmentDetails: View {
    private let attachments: [PhotoAttachment]
    private let action: (UUID, PhotoAttachmentAction) -> Void
    private let remove: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

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
        NavigationStack {
            List {
                ForEach(PhotoAttachmentSection.grouping(attachments)) { section in
                    Section {
                        ForEach(section.attachments) { attachment in
                            PhotoAttachmentRow(
                                attachment: attachment,
                                showsExplanation: section.sharedFailureExplanation == nil,
                                action: action, remove: remove)
                                .padding(.vertical, 8)
                        }
                    } footer: {
                        if let explanation = section.sharedFailureExplanation {
                            Text(explanation)
                                .font(.subheadline)
                                .foregroundStyle(Color(uiColor: .secondaryLabel))
                                .accessibilityIdentifier("photo-shared-guidance-\(section.id)")
                        }
                    }
                }
            }
            .overlay {
                if attachments.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Pending Photos", bundle: .module),
                        systemImage: "photo.on.rectangle")
                }
            }
            .navigationTitle(String(localized: "Photos", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .tint(.primary)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("photo-attachment-details")
    }
}

private struct PhotoAttachmentRow: View {
    let attachment: PhotoAttachment
    let showsExplanation: Bool
    let action: (UUID, PhotoAttachmentAction) -> Void
    let remove: (UUID) -> Void

    var body: some View {
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
                                .foregroundStyle(.primary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel(Text("Photo options", bundle: .module))
                        .accessibilityIdentifier("photo-options-\(attachment.id)")
                        .tint(.primary)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    if isBusy(attachment.phase) {
                        ProgressView().controlSize(.small).tint(.secondary).accessibilityHidden(true)
                    }
                    Text(status(attachment.phase)).font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if showsExplanation, let detail = attachment.phase.failureExplanation {
                    Text(detail).font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
                }
                if let guidance = attachment.guidance {
                    Text(guidance).font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photo-attachment-\(attachment.id)")
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
        case .failed: String(localized: "Couldn't upload", bundle: .module)
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

    private func recoveryButton(
        _ recovery: PhotoAttachmentAction, attachment: PhotoAttachment, date: Date
    ) -> some View {
        PhotoActionButton(
            id: "photo-recovery-\(attachment.id)", title: actionTitle(recovery),
            isEnabled: attachment.isActionEnabled(at: date),
            action: { action(attachment.id, recovery) }
        ) {
            Text(actionTitle(recovery))
                .font(.body)
                .foregroundStyle(.primary)
                .frame(minHeight: 44)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct PhotoActionButton<Label: View>: UIViewRepresentable {
    let id: String
    let title: String
    var value: String?
    var hint: String?
    var isEnabled = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.isNotebookPaneVisible) private var isPaneVisible

    func makeUIView(context: Context) -> PhotoActionControl {
        let button = PhotoActionControl(type: .custom)
        button.isAccessibilityElement = true
        button.addAction(UIAction { [weak button] _ in button?.activate?() }, for: .primaryActionTriggered)
        return button
    }

    func updateUIView(_ button: PhotoActionControl, context: Context) {
        button.activate = action
        button.isHidden = !isPaneVisible
        button.isAccessibilityElement = isPaneVisible
        button.accessibilityElementsHidden = !isPaneVisible
        button.isEnabled = isEnabled
        button.accessibilityIdentifier = id
        button.accessibilityLabel = title
        button.accessibilityValue = value
        button.accessibilityHint = hint
        let configuration = UIHostingConfiguration { label() }.margins(.all, 0)
        if let content = button.hostedContent {
            content.configuration = configuration
        } else {
            let content = configuration.makeContentView()
            content.isUserInteractionEnabled = false
            content.accessibilityElementsHidden = true
            content.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                content.topAnchor.constraint(equalTo: button.topAnchor),
                content.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            button.hostedContent = content
        }
        button.hostedContent?.alpha = isEnabled ? 1 : 0.4
        button.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhotoActionControl, context: Context) -> CGSize? {
        guard let content = uiView.hostedContent else { return nil }
        return content.systemLayoutSizeFitting(
            CGSize(width: proposal.width ?? UIView.layoutFittingExpandedSize.width, height: 0),
            withHorizontalFittingPriority: proposal.width == nil ? .fittingSizeLevel : .required,
            verticalFittingPriority: .fittingSizeLevel)
    }
}

private final class PhotoActionControl: UIButton {
    var activate: (() -> Void)?
    var hostedContent: (UIView & UIContentView)?

    override var isHighlighted: Bool {
        didSet { hostedContent?.alpha = isHighlighted ? 0.55 : (isEnabled ? 1 : 0.4) }
    }
}
#endif
