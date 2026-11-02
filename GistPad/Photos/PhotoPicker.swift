import PhotosUI
import SwiftUI

extension View {
  /// The Photos notice, picker, upload progress and failure for a file's photo uploads.
  func photoPicker(_ photos: PhotoUpload) -> some View {
    modifier(PhotoPicker(photos: photos))
  }
}

struct PhotoPicker: ViewModifier {
  @Bindable var photos: PhotoUpload
  @State private var selection: PhotosPickerItem?

  func body(content: Content) -> some View {
    content
      .alert("Photos Are Public", isPresented: $photos.isShowingNotice) {
        Button(role: .cancel) {}
        Button("Continue") { photos.acceptNotice() }
      } message: {
        Text(
          "Photos you choose are uploaded to GistPad's public image storage. Anyone with the link can view them, even in a secret gist. Location data is removed."
        )
      }
      .photosPicker(
        isPresented: $photos.isShowingPicker, selection: $selection,
        matching: .images, preferredItemEncoding: .current
      )
      .onChange(of: selection) { _, photo in
        guard let photo else { return }
        selection = nil
        Task { await photos.add(photo) }
      }
      .alert(
        "Couldn't Add Photo",
        isPresented: Binding(get: { photos.failure != nil }, set: { if !$0 { photos.failure = nil } }),
        presenting: photos.failure
      ) { failure in
        if let png = failure.png {
          Button("Try Again") { Task { await photos.add(png: png) } }
        }
        Button("Cancel", role: .cancel) {}
      } message: { failure in
        Text(failure.message)
      }
      .toolbar {
        if photos.isUploading {
          ToolbarItem(placement: .primaryAction) {
            ProgressView().accessibilityLabel("Uploading Photo")
          }
        }
      }
  }
}
