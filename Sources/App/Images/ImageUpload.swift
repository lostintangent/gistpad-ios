import Editor
import Foundation
import Model
import Observation
import PhotosUI
import SwiftUI
import Store

/// Adds an image the way gistpad.dev does: upload it to public storage, then insert its Markdown at the cursor.
@Observable
final class ImageUpload {
    var isShowingPicker = false
    var failure: Failure?
    private(set) var isUploading = false
    /// The image the failure's fix adds again.
    @ObservationIgnored private var failedImage: Data?
    /// The note the picked image, or a retried one, goes into.
    @ObservationIgnored private weak var fileEditor: GistFileEditor?
    private let model: GistPadModel

    init(model: GistPadModel) {
        self.model = model
    }

    func canChooseImage(for fileEditor: GistFileEditor) -> Bool {
        !isUploading && fileEditor.canEdit && !fileEditor.file.isDeletedOnGitHub
    }

    func chooseImage(for fileEditor: GistFileEditor) {
        guard canChooseImage(for: fileEditor) else { return }
        self.fileEditor = fileEditor
        fileEditor.editor.endEditing()
        isShowingPicker = true
    }

    func add(_ item: PhotosPickerItem) async {
        isUploading = true
        defer { isUploading = false }
        do {
            guard let image = try? await item.loadTransferable(type: Data.self) else {
                throw ImageError.unreadable
            }
            try ImageStorage.check(image)
            await add(image: image)
        } catch {
            failure = Failure(error)
        }
    }

    func add(image: Data) async {
        guard let fileEditor else { return }
        isUploading = true
        defer { isUploading = false }
        if fileEditor.file.gistID == nil { await fileEditor.publish() }
        guard fileEditor.file.gistID != nil else {
            failure = Failure(String(localized: "You can add images after this gist publishes."), action: .tryAgain)
            failedImage = image
            return
        }
        do {
            let markdown = ImageStorage.markdown(try await model.uploadImage(image, for: fileEditor.file))
            let editor = fileEditor.editor
            try editor.apply(
                Edit(
                    range: NSRange(location: NSMaxRange(editor.selection), length: 0), expected: "",
                    replacement: markdown),
                generation: editor.generation)
        } catch {
            failure = Failure(error)
            failedImage = image
        }
    }

    /// Signs in again first when that's the fix, then adds the image again.
    func recover(from failure: Failure) async {
        if failure.action == .reconnect { await model.reconnect() }
        guard let failedImage else { return }
        await add(image: failedImage)
    }
}
