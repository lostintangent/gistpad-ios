import PhotosUI
import SwiftUI

extension View {
  /// The picker, upload progress and failure for a file's image uploads.
  func imagePicker(_ images: ImageUpload) -> some View {
    modifier(ImagePicker(images: images))
  }
}

struct ImagePicker: ViewModifier {
  @Bindable var images: ImageUpload
  @State private var selection: PhotosPickerItem?

  func body(content: Content) -> some View {
    content
      .photosPicker(
        isPresented: $images.isShowingPicker, selection: $selection,
        matching: .images, preferredItemEncoding: .current
      )
      .onChange(of: selection) { _, item in
        guard let item else { return }
        selection = nil
        Task { await images.add(item) }
      }
      .alert(
        "Couldn't Add Image",
        isPresented: Binding(get: { images.failure != nil }, set: { if !$0 { images.failure = nil } }),
        presenting: images.failure
      ) { failure in
        if let png = failure.png {
          Button("Try Again") { Task { await images.add(png: png) } }
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
