import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = BoardStore()
    lazy var controller = BoardController(store: store)

    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var toggleItem: NSMenuItem!
    private var clearItem: NSMenuItem!
    private var popoutItem: NSMenuItem!
    private var windowItem: NSMenuItem!
    private var pinnedItem: NSMenuItem!
    private var soundsItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One board at a time.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }

        controller.setup()
        setupStatusItem()

        // ⇧⌘H brings the board back from anywhere; ⌘H (handled below) hides it, like any app.
        hotKey = HotKey(keyCode: kVK_ANSI_H, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.controller.show()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }

        if controller.style != .pinned { controller.show() }

        // First launch: walk through the basics by doing them.
        if !UserDefaults.standard.bool(forKey: "tutorialDone") {
            controller.show()
            store.startTutorial()
        }
    }

    /// Clicking Board in the Dock (or opening it again from Finder) while it's running brings the board back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.endEditing()
        store.saveNow()
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === controller.board else { return event }
        let typing = controller.board.firstResponder is NSTextView
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // Return / Enter answers "Yes" to whichever prompt is showing (Esc, below, dismisses it).
        let isReturn = event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
        if isReturn, mods.isEmpty, let id = store.confirmingRemoveID {
            store.remove(id)
            return nil
        }
        if isReturn, mods.isEmpty, !typing, let id = store.datePromptID {
            store.moveNoteToDeadlines(id)
            return nil
        }
        if event.keyCode == UInt16(kVK_Escape) {
            if store.confirmingRemoveID != nil {
                store.confirmingRemoveID = nil
            } else if store.datePromptID != nil {
                store.datePromptID = nil
            } else if store.selectedID != nil {
                store.selectedID = nil
            } else if typing || store.editingID != nil {
                store.endEditing()
            } else {
                controller.hide()
            }
            return nil
        }
        // Delete on a selected photo asks to remove it, like deleting a picture in Pages.
        if !typing, mods.isEmpty, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete),
           let id = store.selectedID {
            store.confirmingRemoveID = id
            return nil
        }
        // ⌘H hides, even mid-typing — same as hiding any other app.
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "h" {
            controller.hide()
            return nil
        }
        // Pasting a picture while typing in a card: a text field can't take it, so pin it instead.
        if typing, mods == .command, event.charactersIgnoringModifiers?.lowercased() == "v",
           BoardStore.hasPicture(.general), NSPasteboard.general.string(forType: .string) == nil {
            store.endEditing()
            store.paste(at: controller.pointerOnBoard())
            return nil
        }
        guard !typing, mods == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
        switch key {
        case "n": store.add(.note, at: store.randomSpot())
        case "l": store.add(.list, at: store.randomSpot())
        case "d": store.add(.deadlines, at: store.randomSpot())
        case "v": if !store.paste(at: controller.pointerOnBoard()) { NSSound.beep() }
        case "z": store.undo()
        case "w": controller.hide()
        default: return event
        }
        return nil
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.toolTip = "Board"

        let menu = NSMenu()
        menu.delegate = self

        toggleItem = add(menu, "Show Board", #selector(toggleBoard), key: "h", mods: [.command, .shift])
        add(menu, "New Note", #selector(newNote))
        add(menu, "New List", #selector(newList))
        add(menu, "New Deadlines", #selector(newDeadlines))
        clearItem = add(menu, "Clear Done", #selector(clearDone))
        menu.addItem(.separator())

        let styleHeader = NSMenuItem(title: "Board Style", action: nil, keyEquivalent: "")
        styleHeader.isEnabled = false
        menu.addItem(styleHeader)
        popoutItem = add(menu, "Floating — always on top", #selector(setPopout))
        windowItem = add(menu, "Window — other windows can cover it", #selector(setWindow))
        pinnedItem = add(menu, "Pinned to Desktop — behind everything", #selector(setPinned))
        menu.addItem(.separator())

        soundsItem = add(menu, "Sounds", #selector(toggleSounds))
        loginItem = add(menu, "Open at Login", #selector(toggleLogin))
        add(menu, "Show Tutorial", #selector(showTutorial))
        add(menu, "Reset Board Position", #selector(resetPosition))
        add(menu, "Show Board Data in Finder", #selector(revealData))
        menu.addItem(.separator())
        add(menu, "Quit Board", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)

        statusItem.menu = menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                     mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = target ?? self
        menu.addItem(item)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        toggleItem.title = controller.isShown ? "Hide Board" : "Show Board"
        toggleItem.keyEquivalentModifierMask = controller.isShown ? .command : [.command, .shift]
        clearItem.isEnabled = store.hasDone
        popoutItem.state = controller.style == .popout ? .on : .off
        windowItem.state = controller.style == .window ? .on : .off
        pinnedItem.state = controller.style == .pinned ? .on : .off
        soundsItem.state = store.soundsOn ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleBoard() { controller.toggle() }
    @objc private func newNote() { controller.show(); store.add(.note, at: store.randomSpot()) }
    @objc private func newList() { controller.show(); store.add(.list, at: store.randomSpot()) }
    @objc private func newDeadlines() { controller.show(); store.add(.deadlines, at: store.randomSpot()) }
    @objc private func clearDone() { store.clearDone() }
    @objc private func setPopout() { controller.style = .popout }
    @objc private func setWindow() { controller.style = .window }
    @objc private func setPinned() { controller.style = .pinned }
    @objc private func toggleSounds() { store.soundsOn.toggle() }
    @objc private func resetPosition() { controller.resetPosition() }
    @objc private func showTutorial() { controller.show(); store.startTutorial() }
    @objc private func revealData() { NSWorkspace.shared.activateFileViewerSelecting([store.folder]) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nTip: move Board.app into your Applications folder and try again."
            alert.runModal()
        }
    }

    /// A tiny board with a magnet and a card, drawn as a template image so it adapts to light/dark menu bars.
    private static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let board = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: 13, height: 13), xRadius: 2, yRadius: 2)
            board.lineWidth = 1.4
            board.stroke()
            NSBezierPath(rect: NSRect(x: 5.5, y: 7, width: 5.5, height: 5.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 6.6, y: 4.6, width: 3.4, height: 3.4)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
