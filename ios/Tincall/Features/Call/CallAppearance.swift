// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI
import UIKit

enum CallNight {
    static let background = Color(red: 0.19, green: 0.18, blue: 0.24)
    static let lavender = Color(red: 0.66, green: 0.55, blue: 0.86)
    static let rose = Color(red: 0.91, green: 0.36, blue: 0.57)
    static let primaryText = Color(red: 1, green: 0.985, blue: 0.992)
    static let secondaryText = primaryText.opacity(0.80)
    static let userMetadata = Color(red: 0.975, green: 0.875, blue: 0.915).opacity(0.84)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

struct CallPalette {
    var isLight = false
    var colorScheme: ColorScheme { isLight ? .light : .dark }
    var primaryText: Color { isLight ? Color(red: 0.16, green: 0.15, blue: 0.20) : CallNight.primaryText }
    var secondaryText: Color { isLight ? primaryText.opacity(0.82) : CallNight.secondaryText }
    var userMetadata: Color { isLight ? Color(red: 0.36, green: 0.21, blue: 0.29) : CallNight.userMetadata }
    var accent: Color { isLight ? Color(red: 0.48, green: 0.35, blue: 0.63) : CallNight.lavender }
    var fog: Color { isLight ? .white : .black }
}

private struct CallPaletteKey: EnvironmentKey {
    static let defaultValue = CallPalette()
}

extension EnvironmentValues {
    var callPalette: CallPalette {
        get { self[CallPaletteKey.self] }
        set { self[CallPaletteKey.self] = newValue }
    }
}

/// Retained by CallScreen and replaced only when the background data changes.
struct CallBackgroundAppearance {
    let image: UIImage?
    let averageBrightness: Double
    var palette: CallPalette { CallPalette(isLight: averageBrightness > 0.6) }

    init(data: Data?) {
        image = data.flatMap(UIImage.init(data:))
        guard let cgImage = image?.cgImage else {
            averageBrightness = 0
            return
        }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        averageBrightness = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) else { return 0 }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            var brightness = 0.0
            for offset in stride(from: 0, to: buffer.count, by: 4) {
                brightness += 0.2126 * Double(buffer[offset])
                    + 0.7152 * Double(buffer[offset + 1]) + 0.0722 * Double(buffer[offset + 2])
            }
            return brightness / Double(side * side * 255)
        }
    }
}

struct CallBackgroundView: View {
    let image: UIImage?
    let maskOpacity: Double
    @Environment(\.callPalette) private var palette

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [CallNight.background,
                                            Color(red: 0.09, green: 0.09, blue: 0.13)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay { if image != nil { palette.fog.opacity(maskOpacity) } }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
