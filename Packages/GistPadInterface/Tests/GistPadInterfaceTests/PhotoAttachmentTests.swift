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
}
