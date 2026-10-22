// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import ImageIO

/// Only attachment rendering lives here; transcript scrolling remains with its existing owner.
struct CallMessageImages: View {
    let images: [CallImageAsset]
    let imageURL: ((CallImageAsset) throws -> URL)?
    var isOutgoing = false
    @State private var selected: CallImageAsset?

    var body: some View {
        Group {
            if isOutgoing {
                ViewThatFits(in: .horizontal) {
                    outgoingGrid(columnCount: max(1, min(images.count, 3)))
                    outgoingGrid(columnCount: 2)
                    outgoingGrid(columnCount: 1)
                }
            } else {
                imageGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 130))])
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        .fullScreenCover(item: $selected) { image in
            CallImageViewer {
                try await CallStoredImage.load(url: url(image), maximumPixelSize: 1568)
            }
        }
    }

    private func outgoingGrid(columnCount: Int) -> some View {
        imageGrid(columns: Array(repeating: GridItem(.fixed(90)), count: columnCount))
            .frame(width: CGFloat(columnCount) * 98 - 8)
    }

    private func imageGrid(columns: [GridItem]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(images) { image in
                Button { selected = image } label: {
                    CallStoredImage(loadURL: { try url(image) }, maximumPixelSize: 260)
                        .frame(maxWidth: .infinity)
                        .frame(height: 100).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看图片")
            }
        }
    }

    private func url(_ image: CallImageAsset) throws -> URL {
        guard let imageURL else { throw TincallError(message: String(localized: "无法读取消息图片")) }
        return try imageURL(image)
    }
}

private struct CallStoredImage: View {
    let loadURL: () throws -> URL
    let maximumPixelSize: Int
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Label("无法读取消息图片", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else { ProgressView() }
        }
        .task {
            do {
                image = try await Self.load(url: loadURL(), maximumPixelSize: maximumPixelSize)
            } catch { failed = true }
        }
    }

    static func load(url: URL, maximumPixelSize: Int) async throws -> UIImage {
        try await Task.detached {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
                  ] as CFDictionary) else { throw TincallError(message: String(localized: "无法读取消息图片")) }
            return UIImage(cgImage: thumbnail)
        }.value
    }
}

struct CallImageViewer: View {
    let loadImage: () async throws -> UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Group {
                if let image {
                    CallZoomableImage(image: image)
                } else if failed {
                    Label("无法读取消息图片", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.white)
                } else { ProgressView().tint(.white) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(.black.opacity(0.6), in: Circle()).padding()
            }
            .accessibilityLabel("关闭图片")
        }
        .task {
            do { image = try await loadImage() }
            catch { failed = true }
        }
    }
}

private struct CallZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "图片")
        scrollView.addSubview(imageView)
        // The unzoomed image follows the viewport, including rotation and safe-area changes.
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) { }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
