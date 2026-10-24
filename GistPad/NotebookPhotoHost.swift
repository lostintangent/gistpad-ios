import GistPadInterface
import PhotosUI
import SwiftUI

struct NotebookPhotoHost<Content: View>: View {
  @Bindable var controller: NotebookPhotoController
  @ViewBuilder let content: () -> Content
  @State private var selectedPhoto: PhotosPickerItem?
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    content()
      .sheet(
        isPresented: Binding(
          get: { controller.isShowingNotice },
          set: { if !$0 { controller.dismissNotice() } }),
        onDismiss: { controller.noticeDidDismiss() }
      ) {
        PhotoPrivacyNotice(
          proceed: controller.noticeStartsPicker ? { controller.acceptNotice() } : nil,
          cancel: { controller.dismissNotice() })
      }
      .photosPicker(
        isPresented: $controller.isShowingPicker, selection: $selectedPhoto,
        matching: .images, preferredItemEncoding: .current)
      .onChange(of: selectedPhoto) { _, photo in
        guard let photo else { return }
        controller.beginPreparing()
        selectedPhoto = nil
        Task {
          do {
            guard let data = try await photo.loadTransferable(type: Data.self) else {
              throw PhotoPickerError.noImageData
            }
            await controller.receivePickedData(data)
          } catch {
            controller.preparationFailed(error)
          }
        }
      }
      .onChange(of: controller.isShowingPicker) { _, showing in
        if !showing, selectedPhoto == nil { controller.pickerCancelled() }
      }
      .confirmationDialog(
        "Remove Pending Photo?",
        isPresented: Binding(
          get: { controller.removalID != nil },
          set: { if !$0 { controller.removalID = nil } }),
        titleVisibility: .visible
      ) {
        Button("Remove Pending Photo", role: .destructive) {
          Task { await controller.removePendingPhoto() }
        }
        Button("Cancel", role: .cancel) { controller.removalID = nil }
      } message: {
        Text("This removes the pending photo from this note. It does not delete any uploaded image.")
      }
      .task { await controller.start() }
      .task(id: controller.publishedGistID) { await controller.resume() }
      .onChange(of: scenePhase) { _, phase in
        Task {
          if phase == .active { await controller.start() }
          else if phase == .background { await controller.stop() }
        }
      }
      .onDisappear { Task { await controller.stop() } }
  }

  private enum PhotoPickerError: Error { case noImageData }
}

struct NotebookPhotoSurface<Content: View>: View {
  @Bindable var controller: NotebookPhotoController
  let isSource: Bool
  var showsAttachments = true
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if showsAttachments {
          VStack(spacing: 0) {
            PhotoAttachmentShelf(
              attachments: controller.displayedAttachments,
              action: { id, action in Task { await controller.perform(action, id: id) } },
              remove: { controller.removalID = $0 })
            if let message = controller.queueError {
              VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.subheadline)
                Button("Retry") { Task { await controller.reload() } }
                  .frame(minHeight: 44)
              }
              .foregroundStyle(.primary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 20)
              .padding(.vertical, 8)
              .background(Color(uiColor: .systemBackground))
            }
          }
        }
      }
  }
}
