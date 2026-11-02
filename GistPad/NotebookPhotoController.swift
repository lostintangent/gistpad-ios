import Foundation
import GistPadEditor
import GistPadSync
import Observation
import PhotosUI
import SwiftUI

/// Adds a photo the way gistpad.dev does: upload it to public storage, then insert its Markdown at the cursor.
@MainActor
@Observable
final class NotebookPhotoController {
  struct Failure {
    let message: String
    let png: Data?
  }

  static let noticeKey = "public-image-storage"
  var isShowingNotice = false
  var isShowingPicker = false
  var failure: Failure?
  private(set) var isUploading = false
  @ObservationIgnored private let note: NotebookSessionController
  @ObservationIgnored private let upload: @MainActor (Data, String) async throws -> URL
  @ObservationIgnored private let defaults: UserDefaults

  init(
    note: NotebookSessionController, defaults: UserDefaults = .standard,
    upload: @escaping @MainActor (Data, String) async throws -> URL
  ) {
    self.note = note
    self.defaults = defaults
    self.upload = upload
  }

  var canChoosePhoto: Bool { !isUploading && note.canMutate && !note.document.isRecovery }

  func choosePhoto() {
    guard canChoosePhoto else { return }
    note.session.textView.resignFirstResponder()
    if defaults.bool(forKey: Self.noticeKey) { isShowingPicker = true } else { isShowingNotice = true }
  }

  func acceptNotice() {
    defaults.set(true, forKey: Self.noticeKey)
    isShowingNotice = false
  }

  func noticeDidDismiss() {
    if defaults.bool(forKey: Self.noticeKey) { isShowingPicker = true }
  }

  func add(_ photo: PhotosPickerItem) async {
    isUploading = true
    defer { isUploading = false }
    do {
      guard let data = try await photo.loadTransferable(type: Data.self) else {
        throw PhotoImageError.invalidImage
      }
      await add(png: try await Task.detached { try PhotoImage.pngData(from: data) }.value)
    } catch {
      failure = Failure(message: Self.message(for: error), png: nil)
    }
  }

  func add(png: Data) async {
    isUploading = true
    defer { isUploading = false }
    if note.draft.gistID == nil { await note.publish() }
    guard let gistID = note.draft.gistID else {
      failure = Failure(message: String(localized: "Publish this gist to upload the photo."), png: png)
      return
    }
    do {
      let markdown = ImageStorageClient.markdown(try await upload(png, gistID))
      let session = note.session
      try session.apply(
        SourceMutation(
          range: NSRange(location: NSMaxRange(session.selection), length: 0), expected: "",
          replacement: markdown),
        documentID: session.documentID, generation: session.generation)
    } catch {
      failure = Failure(message: Self.message(for: error), png: png)
    }
  }

  private static func message(for error: any Error) -> String {
    switch error {
    case PhotoImageError.imageTooLarge: String(localized: "Choose a photo under 50 MB and 100 megapixels.")
    case is PhotoImageError: String(localized: "This item couldn't be read as an image. Choose another photo.")
    case ImageStorageError.http(let status): String(localized: "The image service returned error \(status).")
    default: NotebookModel.message(for: error)
    }
  }
}

extension LiveNotebookProvider {
  func uploadPhoto(_ png: Data, gistID: String, accountID: UUID) async throws -> URL {
    let storage = try await accounts.imageStorageClient(accountID: accountID)
    return try await storage.upload(png, gistID: gistID)
  }
}
