// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct CallRollingCaption: View {
    let text: String
    let fontSize: CGFloat
    @AppStorage(CaptionFontStore.selectionKey) private var fontName = ""
    @State private var fonts = CaptionFontStore.shared
    @State private var followsLatest = true
    @State private var scrollPhase = ScrollPhase.idle
    @State private var fadesTop = false
    @State private var fadesBottom = false
    @State private var contentOverflows = false
    private let bottomID = "caption-bottom"

    private var captionFont: UIFont { fonts.font(named: fontName, size: fontSize) }
    private var lineHeight: CGFloat {
        ceil(max(captionFont.lineHeight, UIFont.systemFont(ofSize: fontSize).lineHeight))
    }
    // Reserve both fading edges in addition to five complete, unobscured lines.
    private var fadeHeight: CGFloat { (lineHeight + 6) / 2 }
    private var viewportHeight: CGFloat { Self.maximumHeight(font: captionFont) }

    static func maximumHeight(font: UIFont, lines: Int = 5) -> CGFloat {
        let lineHeight = ceil(max(font.lineHeight, UIFont.systemFont(ofSize: font.pointSize).lineHeight))
        return (lineHeight + 6) + lineHeight * CGFloat(lines) + CGFloat(lines - 1) * 6 + 8
    }

    private var captionContent: some View {
        Text(text)
            .font(Font(captionFont))
            .lineSpacing(6)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }

    var body: some View {
        // The hidden original sizes this viewport immediately as lines arrive.
        // Its capped height lets the parent center the name and visible text together.
        captionContent
            .hidden()
            .accessibilityHidden(true)
            .frame(maxHeight: viewportHeight)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .overlay { scrollingCaption }
    }

    private var scrollingCaption: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                captionContent.id(bottomID)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .scrollEdgeEffectHidden(true)
            .onScrollPhaseChange { old, new, context in
                if old == .interacting || old == .decelerating || new == .interacting {
                    updateFollowing(context.geometry)
                }
                scrollPhase = new
                if new == .idle, followsLatest, contentOverflows { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
                contentOverflows = new.contentSize.height > new.containerSize.height
                fadesTop = new.contentOffset.y + new.contentInsets.top > 1
                fadesBottom = new.contentSize.height + new.contentInsets.bottom
                    - new.contentOffset.y - new.containerSize.height > 1
                if scrollPhase == .interacting || scrollPhase == .decelerating {
                    updateFollowing(new)
                }
                if contentOverflows, followsLatest, scrollPhase == .idle,
                   old.contentSize != new.contentSize || old.containerSize != new.containerSize {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onChange(of: text) { old, new in
                // A new utterance starts at the latest line; streaming never pulls a reader down.
                if !new.hasPrefix(old) { followsLatest = true }
                if contentOverflows, followsLatest, scrollPhase == .idle {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: fadesTop ? [.clear, .black] : [.black, .black],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: fadeHeight)
                Rectangle()
                LinearGradient(colors: fadesBottom && !followsLatest ? [.black, .clear] : [.black, .black],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: fadeHeight)
            }
        }
    }

    private func updateFollowing(_ geometry: ScrollGeometry) {
        let distance = geometry.contentSize.height + geometry.contentInsets.bottom
            - geometry.contentOffset.y - geometry.containerSize.height
        followsLatest = distance <= 1
    }
}
