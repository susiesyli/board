import SwiftUI
import UniformTypeIdentifiers

/// Nearly square, like a cut sheet of steel.
let boardRadius: CGFloat = 1

struct BoardView: View {
    @EnvironmentObject var store: BoardStore
    @EnvironmentObject var controller: BoardController
    @State private var dropTargeted = false
    @State private var hovering = Renderer.isRendering

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                AluminumSurface()
                    .frame(width: geo.size.width, height: geo.size.height)

                // The bare metal: drag to move the whole board, click to stop editing,
                // double-click to pin a note, right-click for everything else.
                if !Renderer.isRendering { boardTracker(geo.size) }

                if store.cards.isEmpty && store.tutorialStep == nil {
                    EmptyHint().frame(width: geo.size.width, height: geo.size.height)
                }

                ForEach(store.cards) { card in
                    CardView(card: card, boardSize: geo.size)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85, anchor: anchor(card, geo.size)).combined(with: .opacity),
                            removal: .scale(scale: 0.6, anchor: anchor(card, geo.size)).combined(with: .opacity)
                        ))
                }

                // Small print along the top edge, only while the pointer is on the board.
                BoardControls()
                    .frame(width: geo.size.width)
                    .opacity(hovering && store.draggingID == nil ? 1 : 0)
                    .allowsHitTesting(hovering)

                if !Renderer.isRendering { ResizeHandles(size: geo.size) }
            }
            .coordinateSpace(name: "board")
            // The first-run walkthrough, drawn right where things happen on the board.
            .overlayPreferenceValue(TutorialAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    TutorialLayer(targets: anchors.mapValues { proxy[$0] }, size: proxy.size)
                }
            }
            .onAppear { store.boardSize = geo.size }
            .onChange(of: geo.size) { _, size in store.boardSize = size }
            .onDrop(of: [.image, .fileURL, .plainText], isTargeted: $dropTargeted) { providers, location in
                handleDrop(providers, at: location)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: boardRadius, style: .continuous))
        .overlay(BoardRim(radius: boardRadius))
        .overlay {
            if dropTargeted {
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func boardTracker(_ size: CGSize) -> some View {
        MouseTracker(
            onDown: { controller.beginBoardGesture() },
            onDrag: { controller.moveBoard(by: $0) },
            onUp: { moved in if moved { controller.endBoardGesture() } },
            onHover: { h in withAnimation(.easeOut(duration: 0.25)) { hovering = h } },
            onClick: { count, p in
                if count == 2 { store.add(.note, at: p) } else { store.endEditing() }
            },
            dragCursor: .closedHand,
            menu: { boardMenu(at: $0) }
        )
        .frame(width: size.width, height: size.height)
    }

    private func anchor(_ card: Card, _ size: CGSize) -> UnitPoint {
        UnitPoint(x: card.x / max(size.width, 1), y: card.y / max(size.height, 1))
    }

    private func boardMenu(at p: CGPoint) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("New Note") { store.add(.note, at: p) })
        menu.addItem(ActionMenuItem("New List") { store.add(.list, at: p) })
        menu.addItem(ActionMenuItem("New Deadlines") { store.add(.deadlines, at: p) })
        menu.addItem(ActionMenuItem("New Label") { store.add(.label, at: p) })
        menu.addItem(ActionMenuItem("Add Photos…") { controller.pickPhotos() })
        menu.addItem(.separator())
        let clear = ActionMenuItem("Clear Done") { store.clearDone() }
        clear.isEnabled = store.hasDone
        menu.addItem(clear)
        menu.addItem(ActionMenuItem("Hide Board  ⌘H") { controller.hide() })
        menu.autoenablesItems = false
        return menu
    }

    private func handleDrop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        var handled = false
        for (i, provider) in providers.enumerated() {
            let spot = location + CGSize(width: i * 20, height: i * 20)
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // Covers image files from Finder and *promised* images (Photos app, screenshot
                // thumbnails, browsers) — the temp file only lives during this callback.
                handled = true
                _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    DispatchQueue.main.async {
                        if let image = NSImage(data: data) { store.addPhoto(image: image, at: spot) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { store.addPhoto(fileURL: url, at: spot) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    DispatchQueue.main.async { store.addPhoto(image: image, at: spot) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    DispatchQueue.main.async { store.addText(text, at: spot) }
                }
            }
        }
        return handled
    }
}

/// An NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

// MARK: - Controls

/// The board's only controls: a line of small print, like the header strip on a poster.
struct BoardControls: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        HStack(spacing: 14) {
            TimelineView(.everyMinute) { ctx in
                Text(ctx.date, format: .dateTime.weekday(.abbreviated).day(.twoDigits).month(.abbreviated))
                    .smallCaps()
            }
            .foregroundStyle(Color(white: 0.12).opacity(0.55))
            .allowsHitTesting(false)
            Spacer(minLength: 8)
            // Only what has no direct gesture yet: notes are a double-click, photos are a
            // drop or paste, deadlines come from writing a date in a note, hiding is ⌘H.
            item("+ List") { store.add(.list, at: store.randomSpot()) }
            if store.hasDone {
                item("Clear done") { store.clearDone() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func item(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).smallCaps() }
            .buttonStyle(PrintLinkStyle())
    }
}

struct PrintLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(white: 0.08).opacity(configuration.isPressed ? 1 : 0.72))
            .padding(.vertical, 3)
            .contentShape(Rectangle())
    }
}

struct EmptyHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Double-click to pin a note")
            Text("Right-click for more  ·  drop photos anywhere")
        }
        .smallCaps()
        .foregroundStyle(Color(white: 0.1).opacity(0.5))
        .allowsHitTesting(false)
    }
}

// MARK: - Resizing

/// Invisible strips along every edge and corner of the board — grab any of them to resize.
struct ResizeHandles: View {
    @EnvironmentObject var controller: BoardController
    let size: CGSize

    private let edge: CGFloat = 6
    private let corner: CGFloat = 18

    var body: some View {
        let w = size.width, h = size.height
        let midW = max(0, w - corner * 2), midH = max(0, h - corner * 2)
        ZStack(alignment: .topLeading) {
            handle(.top, CGRect(x: corner, y: 0, width: midW, height: edge))
            handle(.bottom, CGRect(x: corner, y: h - edge, width: midW, height: edge))
            handle(.leading, CGRect(x: 0, y: corner, width: edge, height: midH))
            handle(.trailing, CGRect(x: w - edge, y: corner, width: edge, height: midH))
            handle([.top, .leading], CGRect(x: 0, y: 0, width: corner, height: corner))
            handle([.top, .trailing], CGRect(x: w - corner, y: 0, width: corner, height: corner))
            handle([.bottom, .leading], CGRect(x: 0, y: h - corner, width: corner, height: corner))
            handle([.bottom, .trailing], CGRect(x: w - corner, y: h - corner, width: corner, height: corner))
        }
    }

    private func handle(_ edges: Edge.Set, _ r: CGRect) -> some View {
        let cursor = Self.cursor(for: edges)
        return MouseTracker(
            onDown: { controller.beginBoardGesture() },
            onDrag: { controller.resizeBoard(by: $0, edges: edges) },
            onUp: { _ in controller.endBoardGesture() },
            dragCursor: cursor,
            hoverCursor: cursor
        )
        .frame(width: r.width, height: r.height)
        .position(x: r.midX, y: r.midY)
    }

    static func cursor(for edges: Edge.Set) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch edges {
            case [.top, .leading]: .topLeft
            case [.top, .trailing]: .topRight
            case [.bottom, .leading]: .bottomLeft
            case [.bottom, .trailing]: .bottomRight
            case .top: .top
            case .bottom: .bottom
            case .leading: .left
            default: .right
            }
            return .frameResize(position: position, directions: .all)
        }
        if edges == .leading || edges == .trailing { return .resizeLeftRight }
        if edges == .top || edges == .bottom { return .resizeUpDown }
        return .crosshair
    }
}

// MARK: - Edge tab

/// A small steel tab that always peeks out from the screen edge, showing how many
/// things are still open. Click to toggle, drag to slide it up/down.
struct TabHandle: View {
    @EnvironmentObject var store: BoardStore
    @EnvironmentObject var controller: BoardController
    @State private var hover = false

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, style: .continuous)
        let out = hover || controller.isShown
        ZStack {
            AluminumSurface(scratches: false)
                .clipShape(shape)
                .overlay(shape.stroke(Color.black.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 2.5, x: -1, y: 1)
            VStack(spacing: 6) {
                // A tiny red dot when something is due today or late.
                Circle()
                    .fill(Print.red)
                    .frame(width: 5, height: 5)
                    .opacity(store.urgentCount() > 0 ? 1 : 0)
                Text(store.openCount == 0 ? "—" : "\(store.openCount)")
                    .font(Print.sans(Print.titleSize, .light))
                    .monospacedDigit()
                Text("Open").smallCaps(tracking: 0.4)
            }
            .foregroundStyle(Color(white: 0.1).opacity(0.75))
            .frame(width: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
        }
        .frame(width: 34, height: 84)
        .offset(x: out ? 4 : 14)
        .frame(width: 38, height: 92, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(MouseTracker(
            onDown: { controller.beginTabDrag() },
            onDrag: { controller.dragTab(by: $0) },
            onUp: { controller.endTabDrag(moved: $0) },
            onHover: { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover = h } }
        ))
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: controller.isShown)
        .help("Click to show/hide (⇧⌘H / ⌘H), drag to move")
    }
}
