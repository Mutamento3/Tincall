// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct CallIdentityPortrait: View {
    let name: String
    let data: Data?
    let size: CGFloat
    var coversFrame = true

    var body: some View {
        ZStack {
            Rectangle()
                .stroke(Color.primary.opacity(0.5), lineWidth: 0.75)
                .rotationEffect(.degrees(8))
            Group {
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.14))
                        .background(coversFrame ? Color(.systemBackground) : Color.clear)
                        .overlay {
                            Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)))
                                .font(.system(size: size * 0.4, weight: .medium, design: .serif))
                                .foregroundStyle(.primary)
                        }
                }
            }
            .frame(width: size, height: size)
            .clipped()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CallRoundPortrait: View {
    let name: String
    let data: Data?
    let color: Color
    let size: CGFloat
    let isSpeaking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(color.gradient)
                    .overlay {
                        Text(String(name.prefix(1)))
                            .font(CallNight.font(size * 0.36, weight: .medium))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .background { if isSpeaking && !reduceMotion { CallSpeakingRipple(size: size) } }
        .shadow(color: color.opacity(0.12), radius: 18, y: 6)
        .overlay { Circle().strokeBorder(.white, lineWidth: 2.5) }
        .accessibilityLabel(name)
        .accessibilityValue(isSpeaking ? String(localized: "正在说话") : "")
    }
}

private struct CallSpeakingRipple: View {
    let size: CGFloat
    @Environment(\.callPalette) private var palette
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            ZStack {
                ForEach(0..<3) { index in
                    let phase = (elapsed / 2.4 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke((palette.isLight ? palette.accent : .white).opacity(0.22 * (1 - phase)), lineWidth: 1)
                        .scaleEffect(1 + phase * 0.75)
                }
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
