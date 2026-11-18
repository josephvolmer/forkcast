import AppKit
import Charts
import ForkcastCore
import SwiftUI

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct Bar: View {
    let fraction: Double
    var color: Color = Palette.teal
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.opacity(0.85))
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction.isFinite ? fraction : 0))))
            }
        }
        .frame(height: height)
    }
}

struct Sparkline: View, Equatable {
    let points: [HistoryPoint]
    var color: Color = Palette.teal
    static func == (a: Sparkline, b: Sparkline) -> Bool {
        a.points.count == b.points.count && a.points.last?.t == b.points.last?.t && a.points.last?.v == b.points.last?.v && a.color == b.color
    }
    var body: some View {
        let pts = points.compactMap { p in p.v.map { (p.t, $0) } }
        if pts.count >= 2 {
            Chart(pts, id: \.0) { p in
                AreaMark(x: .value("t", p.0), y: .value("v", p.1))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", p.0), y: .value("v", p.1))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 22)
            .help("Last 24 hours")
        } else {
            Color.clear.frame(height: 22)
        }
    }
}

struct CopyJSONButton<T: Encodable>: View {
    let value: () -> T
    @State private var copied = false
    var body: some View {
        Button {
            AppModel.copyJSON(value())
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "curlybraces")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Palette.teal : .secondary)
        .help("Copy as JSON")
    }
}

/// A rounded card used for header tiles and panels.
struct Tile<Content: View>: View {
    let title: String
    var source: String?
    var json: (() -> AnyEncodableBox)?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                SectionTitle(title)
                Spacer(minLength: 0)
                if let json { CopyJSONButton { json() } }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
        .help(source ?? "")
    }
}

struct AnyEncodableBox: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to e: Encoder) throws { try value.encode(to: e) }
}

struct Dot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func icon(for path: String?) -> NSImage? {
        guard let path else { return nil }
        if let i = cache[path] { return i }
        let full = NSWorkspace.shared.icon(forFile: path)
        let small = NSImage(size: NSSize(width: 18, height: 18))
        small.lockFocus()
        full.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        small.unlockFocus()
        if cache.count > 150 { cache.removeAll() }
        cache[path] = small
        return small
    }

    /// Menu bar icon: the fork (template image, so macOS tints it for light and dark menu bars).
    static let menuFork: NSImage = {
        let img = Bundle.main.image(forResource: "MenuIcon") ?? NSImage(systemSymbolName: "fork.knife", accessibilityDescription: "Forkcast")!
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        img.accessibilityDescription = "Forkcast"
        return img
    }()
}

struct AppIcon: View {
    let path: String?
    var kind: String = "app"
    var body: some View {
        Group {
            if let img = Icons.icon(for: path) {
                Image(nsImage: img).resizable()
            } else {
                Image(systemName: kind == "registered" ? "shippingbox" : kind == "job" ? "terminal" : kind == "system" ? "cpu" : "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Reports whether the hosting window is really on screen (window occlusion), which SwiftUI's
/// onAppear/onDisappear don't do reliably for menu bar panels.
struct VisibilityReader: NSViewRepresentable {
    let onChange: (ObjectIdentifier, Bool) -> Void
    func makeNSView(context: Context) -> Probe { Probe(onChange: onChange) }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        let onChange: (ObjectIdentifier, Bool) -> Void
        private var tokens: [NSObjectProtocol] = []
        private weak var lastWindow: NSWindow?
        init(onChange: @escaping (ObjectIdentifier, Bool) -> Void) { self.onChange = onChange; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            if let old = lastWindow, old !== window { onChange(ObjectIdentifier(old), false) }
            lastWindow = window
            guard let w = window else { return }
            for n in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] note in
                    self?.report(closing: note.name == NSWindow.willCloseNotification)
                })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard let w = window else { return }
            onChange(ObjectIdentifier(w), !closing && w.isVisible && w.occlusionState.contains(.visible))
        }
    }
}
