import Editor
import Foundation
import Model
import Observation
import PhotosUI
import SwiftUI
import Store

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
  /// The note the picked image, or a retried one, goes into.
  @ObservationIgnored private weak var fileEditor: GistFileEditor?
  @ObservationIgnored private let upload: @MainActor (Data, String, UUID) async throws -> URL

  init(upload: @escaping @MainActor (Data, String, UUID) async throws -> URL) {
    self.upload = upload
  }

  func canChooseImage(for fileEditor: GistFileEditor) -> Bool {
    !isUploading && fileEditor.canMutate && !fileEditor.file.isRecovery
  }

  func chooseImage(for fileEditor: GistFileEditor) {
    guard canChooseImage(for: fileEditor) else { return }
    self.fileEditor = fileEditor
    fileEditor.editor.textView.resignFirstResponder()
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
    guard let fileEditor else { return }
    isUploading = true
    defer { isUploading = false }
    if fileEditor.draft.gistID == nil { await fileEditor.publish() }
    guard let gistID = fileEditor.draft.gistID else {
      failure = Failure(message: String(localized: "Publish this gist to upload the image."), image: image)
      return
    }
    do {
      let markdown = ImageStorage.markdown(
        try await upload(image, gistID, fileEditor.draft.accountID))
      let editor = fileEditor.editor
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
