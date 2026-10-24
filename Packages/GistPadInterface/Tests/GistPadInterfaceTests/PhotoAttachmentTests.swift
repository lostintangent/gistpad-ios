import Foundation
import Testing
@testable import GistPadInterface

@Suite struct PhotoAttachmentTests {
    @Test func retryHonorsTheExactServerDeadlineWithoutChangingPhase() {
        let deadline = Date(timeIntervalSince1970: 100)
        let photo = PhotoAttachment(
            id: UUID(), phase: .failed(message: "Wait", retryAfter: deadline), action: .retry
        )
        #expect(!photo.isActionEnabled(at: deadline.addingTimeInterval(-0.001)))
        #expect(photo.isActionEnabled(at: deadline))
        #expect(photo.isActionEnabled(at: deadline.addingTimeInterval(1)))
        #expect(photo.phase == .failed(message: "Wait", retryAfter: deadline))
    }

    @Test func anUploadedPhotoStillRequiresASafeActiveTarget() {
        var photo = PhotoAttachment(
            id: UUID(), phase: .ready, action: .insertHere, actionEnabled: false
        )
        #expect(!photo.isActionEnabled(at: .now))
        photo.actionEnabled = true
        #expect(photo.isActionEnabled(at: .now))
        photo.action = nil
        #expect(!photo.isActionEnabled(at: .now))
    }

    @Test func summaryCountsOnlyActualUploadAndPreparationFailures() {
        let phases: [PhotoAttachmentPhase] = [
            .preparing, .queued, .waitingForNote, .uploading, .checking, .offline,
            .reconnect, .ready, .failed(message: "Retained"), .localFailure(message: "Retained"),
            .preparationFailed(message: "Choose another"),
        ]
        let photos = phases.map { PhotoAttachment(id: UUID(), phase: $0) }
        #expect(photos.filter(\.hasFailure).count == 3)
        #expect(!photos[5].hasFailure)
        #expect(!photos[6].hasFailure)
    }

    @Test func identicalFailureGuidanceAppearsOnceWithoutLosingDistinctReasons() {
        let first = PhotoAttachment(id: UUID(), phase: .failed(message: "Kept on this iPhone"))
        let distinct = PhotoAttachment(id: UUID(), phase: .failed(message: "Reconnect GitHub"))
        let repeated = PhotoAttachment(id: UUID(), phase: .failed(message: "Kept on this iPhone"))
        let sections = PhotoAttachmentSection.grouping([first, distinct, repeated])
        #expect(sections.count == 2)
        #expect(sections[0].attachments.map(\.id) == [first.id, repeated.id])
        #expect(sections[0].sharedFailureExplanation == "Kept on this iPhone")
        #expect(sections[1].attachments == [distinct])
        #expect(sections[1].sharedFailureExplanation == nil)
        #expect(sections[1].attachments.first?.failureExplanation == "Reconnect GitHub")
    }

    @Test func ordinaryStatusesKeepTheirOrderAndNeverGainFailureFooters() {
        let photos: [PhotoAttachment] = [
            .init(id: UUID(), phase: .preparing),
            .init(id: UUID(), phase: .offline),
            .init(id: UUID(), phase: .ready),
        ]
        let sections = PhotoAttachmentSection.grouping(photos)
        #expect(sections.count == 1)
        #expect(sections[0].attachments == photos)
        #expect(sections[0].sharedFailureExplanation == nil)
        #expect(PhotoAttachmentSection.grouping([]).isEmpty)
    }
}
