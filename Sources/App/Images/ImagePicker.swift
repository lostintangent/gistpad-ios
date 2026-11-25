import PhotosUI
import Screens
import Store
import SwiftUI

extension View {
    /// The picker, upload progress and failure for a file's image uploads.
    func imagePicker(_ images: ImageUpload) -> some View {
        modifier(ImagePicker(images: images))
    }
}

private struct ImagePicker: ViewModifier {
    @Bindable var images: ImageUpload
    @State private var selection: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $images.isShowingPicker, selection: $selection,
                matching: .images, preferredItemEncoding: .compatible
            )
            .photosPickerMetadataOptions(.removeLocation)
            .onChange(of: selection) { _, item in
                guard let item else { return }
                selection = nil
                Task { await images.add(item) }
            }
            .alert("Couldn’t Add Image", item: $images.failure) { failure in
                if let action = failure.action {
                    Button(action.title) { Task { await images.recover(from: failure) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
            .toolbar {
                if images.isUploading {
                    ToolbarItem(placement: .primaryAction) {
                        ProgressView().accessibilityLabel("Uploading Image")
                    }
                }
            }
    }
}
