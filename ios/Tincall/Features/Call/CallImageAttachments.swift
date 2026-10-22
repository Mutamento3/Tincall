// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import PhotosUI
import AVFoundation
import ImageIO

struct CallDraftImage: Identifiable {
    let id = UUID()
    let jpeg: Data
}

enum CallImageCompression {
    nonisolated static func jpeg(data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1568,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else {
            throw TincallError(message: String(localized: "无法读取或压缩这张图片，请重新选择"))
        }
        return jpeg
    }
}

struct CallAttachmentButton: View {
    @Binding var images: [CallDraftImage]
    @Binding var isLoading: Bool
    @Binding var isPickerActive: Bool
    let isExpanded: Bool
    let onHangUp: () -> Void
    let onPickerDismiss: () -> Void
    let onNotice: (String) -> Void
    @Environment(\.callPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPhotos: [PHPickerResult] = []
    @State private var photoSelectionID = UUID()
    @State private var showsPhotos = false
    @State private var showsCamera = false

    var body: some View {
        ZStack {
            // One persistent glass surface and symbol; only the native action changes.
            Image(systemName: isExpanded ? "plus" : "phone.down.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(isExpanded ? palette.primaryText : .white)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if isExpanded {
                CallAttachmentMenu(canAdd: images.count < 4, onPhotos: {
                    isPickerActive = true
                    showsPhotos = true
                }, onCamera: {
                    isPickerActive = true
                    Task { await openCamera() }
                })
            } else {
                Button(action: onHangUp) {
                    Color.clear.contentShape(Circle())
                }
            }
        }
        .frame(width: 44, height: 44)
        .modifier(CallControlSurface(tint: isExpanded ? nil : Color(red: 0.87, green: 0.25, blue: 0.33)))
        .frame(height: 48)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .accessibilityLabel(isExpanded ? String(localized: "添加图片") : String(localized: "挂断通话"))
        // Restore composer focus after dismissal completes, while its input view stays mounted.
        .sheet(isPresented: $showsPhotos, onDismiss: finishPicking) {
            CallPhotoPicker(selectionLimit: max(1, 4 - images.count)) { results in
                selectedPhotos = results
                photoSelectionID = UUID()
                showsPhotos = false
            }
            .ignoresSafeArea()
        }
        .task(id: photoSelectionID) {
            guard !selectedPhotos.isEmpty else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                var loaded: [CallDraftImage] = []
                for photo in selectedPhotos.prefix(4 - images.count) {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        photo.itemProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, error in
                            if let data { continuation.resume(returning: data) }
                            else {
                                continuation.resume(throwing: error ?? TincallError(message: String(localized: "无法读取或压缩这张图片，请重新选择")))
                            }
                        }
                    }
                    let jpeg = try await Task.detached { try CallImageCompression.jpeg(data: data) }.value
                    try Task.checkCancellation()
                    loaded.append(CallDraftImage(jpeg: jpeg))
                }
                images.append(contentsOf: loaded)
                selectedPhotos = []
            } catch is CancellationError { }
            catch { onNotice(String(localized: "无法读取或压缩这张图片，请重新选择")); selectedPhotos = [] }
        }
        .fullScreenCover(isPresented: $showsCamera, onDismiss: finishPicking) {
            CallCameraPicker { result in
                showsCamera = false
                guard let result else { return }
                do {
                    let jpeg = try result.get()
                    guard images.count < 4 else { onNotice(String(localized: "一次最多发送 4 张图片")); return }
                    images.append(CallDraftImage(jpeg: jpeg))
                } catch { onNotice(String(localized: "无法读取或压缩这张图片，请重新选择")) }
            }
            .ignoresSafeArea()
        }
    }

    private func openCamera() async {
        defer { if !showsCamera { finishPicking() } }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            onNotice(String(localized: "当前设备无法拍照")); return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let granted: Bool
        if status == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: .video) }
        else { granted = status == .authorized }
        guard granted else { onNotice(String(localized: "请在系统设置中允许 Tincall 使用相机")); return }
        showsCamera = true
    }

    private func finishPicking() {
        isPickerActive = false
        onPickerDismiss()
    }
}

private struct CallAttachmentMenu: UIViewRepresentable {
    let canAdd: Bool
    let onPhotos: () -> Void
    let onCamera: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> Button {
        let button = Button(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "添加图片")
        return button
    }

    func updateUIView(_ button: Button, context: Context) {
        button.isEnabled = isEnabled
        let attributes: UIMenuElement.Attributes = canAdd ? [] : .disabled
        button.menu = UIMenu(children: [
            UIAction(title: String(localized: "照片"), image: UIImage(systemName: "photo"), attributes: attributes) { _ in
                onPhotos()
            },
            UIAction(title: String(localized: "拍照"), image: UIImage(systemName: "camera"), attributes: attributes) { _ in
                onCamera()
            }
        ])
    }

    final class Button: UIButton {
        override var canBecomeFirstResponder: Bool { false }
    }
}

private struct CallPhotoPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onSelection: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = selectionLimit
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) { }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelection: ([PHPickerResult]) -> Void
        init(onSelection: @escaping ([PHPickerResult]) -> Void) { self.onSelection = onSelection }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onSelection(results)
        }
    }
}

private struct CallCameraPicker: UIViewControllerRepresentable {
    let onResult: (Result<Data, Error>?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onResult: (Result<Data, Error>?) -> Void
        init(onResult: @escaping (Result<Data, Error>?) -> Void) { self.onResult = onResult }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onResult(nil) }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onResult(Result {
                guard let image = info[.originalImage] as? UIImage else {
                    throw TincallError(message: String(localized: "无法读取或压缩这张图片，请重新选择"))
                }
                // Draw once at the target pixel size to normalize camera orientation.
                let ratio = min(1, 1568 / max(image.size.width * image.scale, image.size.height * image.scale))
                let size = CGSize(width: floor(image.size.width * image.scale * ratio), height: floor(image.size.height * image.scale * ratio))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    UIColor.white.setFill()
                    UIRectFill(CGRect(origin: .zero, size: size))
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                guard let jpeg = resized.jpegData(compressionQuality: 0.8) else {
                    throw TincallError(message: String(localized: "无法读取或压缩这张图片，请重新选择"))
                }
                return jpeg
            })
        }
    }
}

struct CallDraftImageStrip: View {
    @Binding var images: [CallDraftImage]
    @State private var selected: CallDraftImage?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(images) { image in
                if let thumbnail = UIImage(data: image.jpeg) {
                    Button { selected = image } label: {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                            .frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看图片")
                        .overlay(alignment: .topTrailing) {
                            Button { images.removeAll { $0.id == image.id } } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.75)).font(.system(size: 18))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除图片")
                            .offset(x: 7, y: -7)
                        }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .fullScreenCover(item: $selected) { image in
            CallImageViewer {
                guard let image = UIImage(data: image.jpeg) else {
                    throw TincallError(message: String(localized: "无法读取消息图片"))
                }
                return image
            }
        }
    }
}
