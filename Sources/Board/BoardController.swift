import AppKit
import SwiftUI

final class BoardPanel: NSPanel {
    var keyable = true
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
    // Borderless panels may sit partly off-screen while animating.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Lets the first click on an inactive board land on the card you clicked, not just focus the window.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the two windows: the board itself and the pull-tab parked on the screen edge.
@MainActor
final class BoardController: ObservableObject {
    enum Style: String {
        /// Floats over everything, disappears completely when hidden.
        case popout
        /// An ordinary window: stays open, but other windows can cover it. Showing it raises it.
        case window
        /// Lives on the desktop behind your windows like a widget; showing it raises it to the front.
        case pinned
    }

    /// The level the board sits at while shown.
    private var shownLevel: NSWindow.Level { style == .window ? .normal : .floating }

    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    let store: BoardStore
    @Published private(set) var isShown = false
    @Published var style: Style {
        didSet {
            UserDefaults.standard.set(style.rawValue, forKey: "style")
            applyStyle()
        }
    }

    private(set) var board: BoardPanel!
    private var tab: BoardPanel!
    private var restingFrame: NSRect
    private var gestureStartFrame = NSRect.zero
    private var tabStartY: CGFloat = 0

    private let tabSize = NSSize(width: 38, height: 92)

    init(store: BoardStore) {
        self.store = store
        style = Style(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .popout
        restingFrame = Self.savedFrame() ?? Self.defaultFrame()
    }

    // MARK: Setup

    func setup() {
        board = BoardPanel(contentRect: restingFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(board)
        let host = FirstMouseHostingView(rootView: BoardView().environmentObject(store).environmentObject(self))
        host.sizingOptions = []
        board.contentView = host
        store.resignFocus = { [weak self] in _ = self?.board.makeFirstResponder(nil) }

        tab = BoardPanel(contentRect: NSRect(origin: .zero, size: tabSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tab.keyable = false
        configure(tab)
        tab.hasShadow = false
        tab.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let tabHost = FirstMouseHostingView(rootView: TabHandle().environmentObject(store).environmentObject(self))
        tabHost.sizingOptions = []
        tab.contentView = tabHost
        positionTab()
        tab.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.positionTab()
                if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(self.restingFrame) }) {
                    self.resetPosition()
                }
            }
        }

        applyStyle()
    }

    private func configure(_ p: BoardPanel) {
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovable = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    private func applyStyle() {
        guard let board else { return }
        switch style {
        case .popout:
            board.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            board.level = .floating
            if !isShown { board.orderOut(nil) }
        case .window:
            // Follows you to whichever Space you bring it back on.
            board.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
            board.level = .normal
            if !isShown { board.orderOut(nil) }
        case .pinned:
            board.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            if !isShown {
                board.level = Self.desktopLevel
                board.alphaValue = 1
                board.setFrame(restingFrame, display: true)
                board.orderFrontRegardless()
            }
        }
    }

    // MARK: Show / hide

    func toggle() {
        // In window mode, a board that's open but covered comes forward rather than hiding.
        if isShown && style == .window && !board.isKeyWindow {
            show()
        } else {
            isShown ? hide() : show()
        }
    }

    func show() {
        guard !isShown else {
            board.orderFrontRegardless()
            board.makeKey()
            return
        }
        isShown = true
        store.tutorialEvent(.shown)
        board.level = shownLevel
        let target = restingFrame
        if !board.isVisible || board.alphaValue < 1 {
            board.alphaValue = 0
            board.setFrame(target.offsetBy(dx: 26, dy: 0), display: false)
        }
        board.orderFrontRegardless()
        board.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            board.animator().setFrame(target, display: true)
            board.animator().alphaValue = 1
        }
        board.invalidateShadow()
    }

    func hide() {
        guard isShown else { return }
        store.endEditing()
        isShown = false
        store.tutorialEvent(.hidden)
        if style == .pinned {
            // Drop back behind everything, still visible on the desktop.
            board.orderOut(nil)
            board.level = Self.desktopLevel
            board.orderFrontRegardless()
            return
        }
        let target = restingFrame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            board.animator().setFrame(target.offsetBy(dx: 26, dy: 0), display: true)
            board.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.board.orderOut(nil)
                self.board.setFrame(target, display: false)
            }
        })
    }

    // MARK: Moving & resizing the board

    func beginBoardGesture() { gestureStartFrame = board.frame }

    func moveBoard(by d: CGSize) {
        board.setFrameOrigin(NSPoint(x: gestureStartFrame.minX + d.width, y: gestureStartFrame.minY + d.height))
    }

    /// Resizes from whichever edges are being dragged; the opposite edges stay put.
    func resizeBoard(by d: CGSize, edges: Edge.Set) {
        let f = gestureStartFrame
        let minW: CGFloat = 360, minH: CGFloat = 440
        var r = f
        if edges.contains(.trailing) {
            r.size.width = max(minW, f.width + d.width)
        }
        if edges.contains(.leading) {
            r.size.width = max(minW, f.width - d.width)
            r.origin.x = f.maxX - r.width
        }
        // Screen coordinates: y grows upward.
        if edges.contains(.bottom) {
            r.size.height = max(minH, f.height - d.height)
            r.origin.y = f.maxY - r.height
        }
        if edges.contains(.top) {
            r.size.height = max(minH, f.height + d.height)
            r.origin.y = f.minY
        }
        board.setFrame(r, display: true)
    }

    func endBoardGesture() {
        restingFrame = board.frame
        UserDefaults.standard.set(NSStringFromRect(restingFrame), forKey: "boardFrame")
        board.invalidateShadow()
        store.tutorialEvent(.dragged)
    }

    func resetPosition() {
        restingFrame = Self.defaultFrame()
        UserDefaults.standard.removeObject(forKey: "boardFrame")
        if board.isVisible { board.setFrame(restingFrame, display: true, animate: true) }
    }

    private static func savedFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: "boardFrame") else { return nil }
        let r = NSRectFromString(s)
        guard r.width >= 300, r.height >= 300,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) else { return nil }
        return r
    }

    private static func defaultFrame() -> NSRect {
        let vis = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 480
        let h = min(780, vis.height - 80)
        return NSRect(x: vis.maxX - w - 52, y: vis.midY - h / 2, width: w, height: h)
    }

    // MARK: The edge tab

    private var tabScreen: NSRect {
        (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    func positionTab() {
        let vis = tabScreen
        let fraction = CGFloat(UserDefaults.standard.object(forKey: "tabFraction") as? Double ?? 0.62)
        let y = vis.minY + fraction * (vis.height - tabSize.height)
        tab.setFrame(NSRect(x: vis.maxX - tabSize.width, y: y, width: tabSize.width, height: tabSize.height), display: true)
    }

    func beginTabDrag() { tabStartY = tab.frame.minY }

    func dragTab(by d: CGSize) {
        let vis = tabScreen
        let y = min(max(tabStartY + d.height, vis.minY), vis.maxY - tabSize.height)
        tab.setFrameOrigin(NSPoint(x: tab.frame.minX, y: y))
    }

    func endTabDrag(moved: Bool) {
        guard moved else { toggle(); return }
        let vis = tabScreen
        let fraction = (tab.frame.minY - vis.minY) / max(1, vis.height - tabSize.height)
        UserDefaults.standard.set(Double(fraction), forKey: "tabFraction")
    }

    /// Where the pointer is on the board (top-left origin), or nil if it's elsewhere —
    /// so pasted things land under your cursor.
    func pointerOnBoard() -> CGPoint? {
        guard board.isVisible, let content = board.contentView else { return nil }
        let p = content.convert(board.mouseLocationOutsideOfEventStream, from: nil)
        guard content.bounds.insetBy(dx: 30, dy: 30).contains(p) else { return nil }
        return CGPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y)
    }

    // MARK: Photos

    func pickPhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Pick photos to pin on your board"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let spot = store.randomSpot()
        for (i, url) in panel.urls.enumerated() {
            store.addPhoto(fileURL: url, at: spot + CGSize(width: i * 22, height: i * 22))
        }
        show()
    }
}
