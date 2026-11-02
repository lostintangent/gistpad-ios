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
  @ObservationIgnored private weak var note: NotebookSessionController?
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

  var canChoosePhoto: Bool {
    guard let note else { return false }
    return !isUploading && note.canMutate && !note.document.isRecovery
  }

  func choosePhoto() {
    guard canChoosePhoto else { return }
    note?.session.textView.resignFirstResponder()
    if defaults.bool(forKey: Self.noticeKey) { isShowingPicker = true } else { isShowingNotice = true }
  }

  func acceptNotice() {
    defaults.set(true, forKey: Self.noticeKey)
    isShowingPicker = true
  }

  func add(_ photo: PhotosPickerItem) async {
    isUploading = true
    defer { isUploading = false }
    do {
      guard let data = try await photo.loadTransferable(type: Data.self) else {
        throw PhotoStorage.Failure.invalidImage
      }
      await add(png: try await Task.detached { try PhotoStorage.png(from: data) }.value)
    } catch {
      failure = Failure(message: Self.message(for: error), png: nil)
    }
  }

  func add(png: Data) async {
    guard let note else { return }
    isUploading = true
    defer { isUploading = false }
    if note.draft.gistID == nil { await note.publish() }
    guard let gistID = note.draft.gistID else {
      failure = Failure(message: String(localized: "Publish this gist to upload the photo."), png: png)
      return
    }
    do {
      let markdown = PhotoStorage.markdown(try await upload(png, gistID))
      let session = note.session
      try session.apply(
        Edit(
          range: NSRange(location: NSMaxRange(session.textView.selectedRange), length: 0), expected: "",
          replacement: markdown),
        generation: session.generation)
    } catch {
      failure = Failure(message: Self.message(for: error), png: png)
    }
  }

  private static func message(for error: any Error) -> String {
    switch error {
    case PhotoStorage.Failure.imageTooLarge: String(localized: "Choose a photo under 50 MB and 100 megapixels.")
    case PhotoStorage.Failure.http: String(localized: "GistPad's image storage didn't accept the photo.")
    case is PhotoStorage.Failure: String(localized: "This item couldn't be read as an image. Choose another photo.")
    default: error.localizedDescription
    }
  }
}

extension LiveNotebookProvider {
  func uploadPhoto(_ png: Data, gistID: String, accountID: UUID) async throws -> URL {
    let storage = try await accounts.photoStorage(accountID: accountID)
    return try await storage.upload(png, gistID: gistID)
  }
}
