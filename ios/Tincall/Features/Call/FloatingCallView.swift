import SwiftUI

struct FloatingCallView: UIViewControllerRepresentable {
    let name: String
    let status: String
    var avatarData: Data? = nil
    var activity: Activity = .idle
    var caption = ""
    var captionIsOutgoing = false
    let onOpen: () -> Void

    enum Activity { case idle, listening, speaking, replying, muted, connecting, failed }

    func makeUIViewController(context: Context) -> Controller {
        Controller(content: Content(name: name, status: status, avatarData: avatarData, activity: activity), caption: caption, captionIsOutgoing: captionIsOutgoing, onOpen: onOpen)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(content: Content(name: name, status: status, avatarData: avatarData, activity: activity), caption: caption, captionIsOutgoing: captionIsOutgoing, onOpen: onOpen)
    }

    struct Caption: View {
        let text: String
        var isOutgoing = false
        @AppStorage(CaptionFontStore.selectionKey) private var fontName = ""
        @AppStorage("call.textScale") private var textScale = 1.0

        private var compactText: String {
            text.split(whereSeparator: \.isNewline)
                .filter { !$0.allSatisfy(\.isWhitespace) }
                .joined(separator: "\n")
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                if isOutgoing {
                    Text("我")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(compactText)
                    .font(Font(CaptionFontStore.shared.font(named: fontName, size: 13 * textScale)))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    struct Content: View, Equatable {
        let name: String
        let status: String
        let avatarData: Data?
        let activity: Activity
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var retainsListening = false

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && lhs.status == rhs.status && lhs.avatarData == rhs.avatarData && lhs.activity == rhs.activity
        }

        private var displayedActivity: Activity {
            activity == .idle && retainsListening ? .listening : activity
        }

        private var symbol: String {
            switch displayedActivity {
            case .idle: "mic.fill"
            case .listening, .speaking: "waveform"
            case .replying: "ellipsis"
            case .muted: "mic.slash.fill"
            case .connecting: "phone.connection.fill"
            case .failed: "exclamationmark"
            }
        }

        var body: some View {
            ZStack(alignment: .bottom) {
                CallRoundPortrait(name: name, data: avatarData, color: CallNight.lavender,
                                  size: 56, isSpeaking: false)
                    .frame(maxHeight: .infinity, alignment: .top)
                ZStack {
                    statusIcon
                }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: displayedActivity)
                    .font(.system(size: 17, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color("AccentColor"))
                    .compositingGroup()
                    .shadow(color: .white, radius: 0, x: -1, y: 0)
                    .shadow(color: .white, radius: 0, x: 1, y: 0)
                    .shadow(color: .white, radius: 0, x: 0, y: -1)
                    .shadow(color: .white, radius: 0, x: 0, y: 1)
                    .frame(width: 30, height: 30)
            }
            .frame(width: 56, height: 72)
            .task(id: activity) {
                if activity == .listening {
                    retainsListening = true
                } else if activity == .idle && retainsListening {
                    // Bridge brief pauses between syllables in the icon only.
                    // Capture, transcription and interruption keep their real timing.
                    do { try await Task.sleep(for: .milliseconds(600)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    retainsListening = false
                } else {
                    retainsListening = false
                }
            }
        }

        @ViewBuilder private var statusIcon: some View {
            if displayedActivity == .replying {
                TimelineView(.animation(minimumInterval: 0.3, paused: reduceMotion)) { context in
                    let count = reduceMotion ? 3 : Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3 + 1
                    HStack(spacing: 2) {
                        ForEach(0..<3) { index in
                            Circle().frame(width: 3, height: 3).opacity(index < count ? 1 : 0.2)
                        }
                    }
                }
                .transition(.opacity)
            } else if displayedActivity == .listening || displayedActivity == .speaking {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                    .transition(.opacity)
            } else {
                Image(systemName: symbol)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .transition(.opacity)
            }
        }
    }

    final class Controller: UIViewController {
        private let host: UIHostingController<Content>
        private let captionHost: UIHostingController<Caption>
        private var content: Content
        private var caption: String
        private var captionIsOutgoing: Bool
        private var measuredCaptionWidth: CGFloat = -1
        private var captionSize = CGSize.zero
        private var onOpen: () -> Void
        private var dragOrigin = CGPoint.zero
        private var hasPosition = false

        init(content: Content, caption: String, captionIsOutgoing: Bool, onOpen: @escaping () -> Void) {
            self.content = content
            self.caption = caption
            self.captionIsOutgoing = captionIsOutgoing
            self.onOpen = onOpen
            host = UIHostingController(rootView: content)
            captionHost = UIHostingController(rootView: Caption(text: caption, isOutgoing: captionIsOutgoing))
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() { view = PassthroughView() }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(captionHost)
            captionHost.view.backgroundColor = .clear
            captionHost.view.isUserInteractionEnabled = false
            view.addSubview(captionHost.view)
            captionHost.didMove(toParent: self)
            addChild(host)
            host.view.backgroundColor = .clear
            view.addSubview(host.view)
            host.didMove(toParent: self)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
            let tap = UITapGestureRecognizer(target: self, action: #selector(open))
            tap.require(toFail: pan)
            host.view.addGestureRecognizer(pan)
            host.view.addGestureRecognizer(tap)
            updateAccessibility()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            host.view.bounds.size = CGSize(width: min(56, max(0, view.bounds.width - 32)), height: 72)
            let position = hasPosition ? host.view.center : CGPoint(x: view.bounds.maxX, y: view.bounds.maxY)
            host.view.center = clamped(position)
            hasPosition = true
            layoutCaption()
        }

        func update(content: Content, caption: String, captionIsOutgoing: Bool, onOpen: @escaping () -> Void) {
            self.onOpen = onOpen
            // Dragging and unrelated transcript deltas do not rebuild/decode the portrait.
            if self.content != content {
                self.content = content
                host.rootView = content
            }
            if self.caption != caption || self.captionIsOutgoing != captionIsOutgoing {
                self.caption = caption
                self.captionIsOutgoing = captionIsOutgoing
                captionHost.rootView = Caption(text: caption, isOutgoing: captionIsOutgoing)
                measuredCaptionWidth = -1
            }
            if isViewLoaded { updateAccessibility(); layoutCaption() }
        }

        private func updateAccessibility() {
            host.view.isAccessibilityElement = true
            host.view.accessibilityLabel = String(localized: "回到与 \(content.name) 的通话，\(content.status)")
            host.view.accessibilityTraits = .button
            host.view.accessibilityCustomActions = [UIAccessibilityCustomAction(name: String(localized: "打开")) { [weak self] _ in
                self?.onOpen()
                return true
            }]
        }

        @objc private func open() { onOpen() }

        @objc private func drag(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { dragOrigin = host.view.center }
            let translation = gesture.translation(in: view)
            // Move the existing native view at gesture cadence, outside SwiftUI rendering.
            host.view.center = clamped(CGPoint(x: dragOrigin.x + translation.x, y: dragOrigin.y + translation.y))
            layoutCaption()
        }

        private func layoutCaption() {
            captionHost.view.isHidden = caption.isEmpty
            guard !caption.isEmpty else { return }
            let showsOnLeft = host.view.center.x >= view.bounds.midX
            let availableWidth = showsOnLeft ? host.view.frame.minX - 22 : view.bounds.width - host.view.frame.maxX - 22
            let width = min(224, max(0, availableWidth))
            if width != measuredCaptionWidth {
                captionSize = captionHost.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                captionSize.width = width
                measuredCaptionWidth = width
            }
            let x = showsOnLeft ? host.view.frame.minX - 6 - width : host.view.frame.maxX + 6
            let y = min(max(16, host.view.center.y - 8 - captionSize.height / 2), max(16, view.bounds.height - captionSize.height - 16))
            captionHost.view.frame = CGRect(origin: CGPoint(x: x, y: y), size: captionSize)
        }

        private func clamped(_ point: CGPoint) -> CGPoint {
            let halfWidth = host.view.bounds.width / 2
            let halfHeight = host.view.bounds.height / 2
            return CGPoint(x: min(max(halfWidth + 16, point.x), max(halfWidth + 16, view.bounds.width - halfWidth - 16)),
                           y: min(max(halfHeight + 16, point.y), max(halfHeight + 16, view.bounds.height - halfHeight - 16)))
        }
    }

    private final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let target = super.hitTest(point, with: event)
            return target === self ? nil : target
        }
    }
}
