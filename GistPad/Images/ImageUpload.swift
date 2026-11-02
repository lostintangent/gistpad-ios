import Foundation
import GistPadEditor
import GistPadSync
import Observation
import PhotosUI
import SwiftUI

/// Adds an image the way gistpad.dev does: upload it to public storage, then insert its Markdown at the cursor.
@MainActor
@Observable
final class ImageUpload {
  struct Failure {
    let message: String
    let image: Data?
  }

  var isShowingPicker = false
  var failure: Failure?
  private(set) var isUploading = false
  @ObservationIgnored private weak var session: FileSession?
  @ObservationIgnored private let upload: @MainActor (Data, String) async throws -> URL

  init(session: FileSession, upload: @escaping @MainActor (Data, String) async throws -> URL) {
    self.session = session
    self.upload = upload
  }

  var canChooseImage: Bool {
    guard let session else { return false }
    return !isUploading && session.canMutate && !session.file.isRecovery
  }

  func chooseImage() {
    guard canChooseImage else { return }
    session?.editor.textView.resignFirstResponder()
    isShowingPicker = true
  }

  func add(_ item: PhotosPickerItem) async {
    isUploading = true
    defer { isUploading = false }
    do {
      guard let image = try await item.loadTransferable(type: Data.self) else {
        throw ImageStorage.Failure.invalidImage
      }
      try ImageStorage.check(image)
      await add(image: image)
    } catch {
      failure = Failure(message: Self.message(for: error), image: nil)
    }
  }

  func add(image: Data) async {
    guard let session else { return }
    isUploading = true
    defer { isUploading = false }
    if session.draft.gistID == nil { await session.publish() }
    guard let gistID = session.draft.gistID else {
      failure = Failure(message: String(localized: "Publish this gist to upload the image."), image: image)
      return
    }
    do {
      let markdown = ImageStorage.markdown(try await upload(image, gistID))
      let editor = session.editor
      try editor.apply(
        Edit(
          range: NSRange(location: NSMaxRange(editor.textView.selectedRange), length: 0), expected: "",
          replacement: markdown),
        generation: editor.generation)
    } catch {
      failure = Failure(message: Self.message(for: error), image: image)
    }
  }

  private static func message(for error: any Error) -> String {
    switch error {
    case ImageStorage.Failure.imageTooLarge: String(localized: "Choose an image under 50 MB.")
    case ImageStorage.Failure.http: String(localized: "GistPad's image storage didn't accept this image.")
    case is ImageStorage.Failure: String(localized: "This item couldn't be read as an image. Choose another one.")
    default: error.localizedDescription
    }
  }
}

extension GitHubSync {
  func uploadImage(_ image: Data, gistID: String, accountID: UUID) async throws -> URL {
    let storage = try await accounts.imageStorage(accountID: accountID)
    return try await storage.upload(image, gistID: gistID)
  }
}
