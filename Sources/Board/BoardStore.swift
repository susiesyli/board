import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class BoardStore: ObservableObject {
    @Published var cards: [Card] = [] {
        didSet { if !ephemeral { scheduleSave() } }
    }
    @Published var editingID: UUID?
    @Published var draggingID: UUID?
    /// The card currently showing its "Remove? Yes / No" prompt.
    @Published var confirmingRemoveID: UUID?
    /// The note currently asking "Add to deadlines?" because it mentions a date.
    @Published var datePromptID: UUID?
    /// The walkthrough's current step (nil when it isn't running), and whether it was just completed.
    @Published var tutorialStep: TutorialStep?
    @Published var tutorialStepDone = false
    private var tutorialSawHide = false
    /// The card (and deadline row) the walkthrough is pointing at — the note you made in it.
    @Published var tutorialTargetID: UUID?
    @Published var tutorialItemID: UUID?
    /// The selected photo, showing its resize handles.
    @Published var selectedID: UUID?

    /// What the walkthrough points at: your tutorial note if it's still around, else the newest card.
    var tutorialFocusID: UUID? {
        guard tutorialStep != nil else { return nil }
        if let id = tutorialTargetID, card(id) != nil { return id }
        return cards.last?.id
    }

    /// Which row's tick box to point at on a list or deadlines card.
    func tutorialCheckItemID(in c: Card) -> UUID? {
        guard c.id == tutorialFocusID else { return nil }
        if let id = tutorialItemID, c.items.contains(where: { $0.id == id }) { return id }
        return c.items.first(where: { !$0.done })?.id
    }
    /// A deadline row that was just added, briefly highlighted so you can see where it landed.
    @Published var flashItemID: UUID?
    @Published var soundsOn: Bool {
        didSet { UserDefaults.standard.set(soundsOn, forKey: "soundsOn") }
    }

    /// Kept up to date by BoardView so cards created from menus/shortcuts land somewhere sensible.
    var boardSize = CGSize(width: 480, height: 760)
    /// Set by the window controller: drops keyboard focus out of any text field.
    var resignFocus: (() -> Void)?

    let folder: URL
    let imagesFolder: URL
    private let ephemeral: Bool
    private var saveWork: DispatchWorkItem?
    private var undoStack: [[Card]] = []
    private var imageCache: [String: NSImage] = [:]
    private var fileURL: URL { folder.appendingPathComponent("board.json") }

    init(ephemeral: Bool = false) {
        self.ephemeral = ephemeral
        soundsOn = UserDefaults.standard.object(forKey: "soundsOn") as? Bool ?? true
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent(Rename.dataFolderName, isDirectory: true)
        imagesFolder = folder.appendingPathComponent("images", isDirectory: true)
        if ephemeral {
            cards = Self.sampleCards()
        } else {
            try? FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
            load()
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: fileURL) {
            do {
                cards = try JSONDecoder().decode([Card].self, from: data)
                cleanOrphanImages()
                return
            } catch {
                // Never silently clobber a board we failed to read — keep a copy aside.
                let backup = folder.appendingPathComponent("board-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: fileURL, to: backup)
            }
        }
        // A new board starts as a blank sheet; the walkthrough fills it in.
        cards = []
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        guard !ephemeral else { return }
        saveWork?.cancel()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cards) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func cleanOrphanImages() {
        let used = Set(cards.compactMap(\.imageFile))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesFolder.path)) ?? []
        for f in files where !used.contains(f) {
            try? FileManager.default.removeItem(at: imagesFolder.appendingPathComponent(f))
        }
    }

    // MARK: - Lookup & mutation

    func index(of id: UUID) -> Int? { cards.firstIndex { $0.id == id } }
    func card(_ id: UUID) -> Card? { index(of: id).map { cards[$0] } }

    func update(_ id: UUID, _ change: (inout Card) -> Void) {
        guard let i = index(of: id) else { return }
        change(&cards[i])
    }

    func textBinding(_ id: UUID, uppercase: Bool = false) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.card(id)?.text ?? "" },
            set: { [weak self] value in self?.update(id) { $0.text = uppercase ? value.uppercased() : value } }
        )
    }

    func itemBinding(_ id: UUID, _ itemID: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.card(id)?.items.first { $0.id == itemID }?.text ?? "" },
            set: { [weak self] value in
                self?.update(id) { c in
                    if let j = c.items.firstIndex(where: { $0.id == itemID }) { c.items[j].text = value }
                }
            }
        )
    }

    var openCount: Int {
        cards.reduce(0) { n, c in
            switch c.kind {
            case .note: n + (c.done ? 0 : 1)
            case .list, .deadlines: n + c.items.filter { !$0.done && !$0.text.trimmed.isEmpty }.count
            default: n
            }
        }
    }

    /// Open deadline items that are due today or already late.
    func urgentCount(now: Date = Date()) -> Int {
        cards.filter { $0.kind == .deadlines }.reduce(0) { n, c in
            n + c.items.filter { item in
                guard !item.done, let due = item.due else { return false }
                return Due.days(until: due, from: now) <= 0
            }.count
        }
    }

    var hasDone: Bool {
        cards.contains { c in c.kind.hasItems ? c.items.contains(where: \.done) : (c.kind == .note && c.done) }
    }

    func randomSpot() -> CGPoint {
        let w = boardSize.width, h = boardSize.height
        return CGPoint(
            x: .random(in: (w * 0.28)...(max(w * 0.28 + 1, w * 0.72))),
            y: .random(in: 130...max(131, h * 0.55))
        )
    }

    // MARK: - Creating

    @discardableResult
    func add(_ kind: CardKind, at p: CGPoint, edit: Bool = true) -> UUID {
        var c = Card(kind: kind, x: p.x, y: p.y)
        if kind.hasItems { c.items = [ListItem(text: "")] }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
            cards.append(c)
        }
        if edit { beginEditing(c.id) }
        if kind == .note {
            if tutorialStep == .create || tutorialStep == .write { tutorialTargetID = c.id; tutorialItemID = nil }
            tutorialEvent(.noteCreated)
        }
        return c.id
    }

    func addNote(text: String, at p: CGPoint) {
        var c = Card(kind: .note, x: p.x, y: p.y)
        c.text = text
        withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { cards.append(c) }
        offerDeadline(for: c)
    }

    func addList(lines: [String], at p: CGPoint) {
        var c = Card(kind: .list, x: p.x, y: p.y)
        c.items = lines.map { ListItem(text: $0) }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { cards.append(c) }
    }

    @discardableResult
    func addPhoto(fileURL url: URL, at p: CGPoint) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let img = NSImage(contentsOf: url) else { return false }
        return addPhoto(image: img, at: p)
    }

    @discardableResult
    func addPhoto(image: NSImage, at p: CGPoint) -> Bool {
        guard let data = Self.jpegData(image, maxPixel: 1400) else { return false }
        let name = UUID().uuidString + ".jpg"
        if !ephemeral {
            do { try data.write(to: imagesFolder.appendingPathComponent(name)) } catch { return false }
        }
        var c = Card(kind: .photo, x: p.x, y: p.y)
        c.imageFile = name
        imageCache[name] = NSImage(data: data)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { cards.append(c) }
        tutorialEvent(.photoAdded)
        return true
    }

    func image(for card: Card) -> NSImage? {
        guard let name = card.imageFile else { return nil }
        if let img = imageCache[name] { return img }
        let img = NSImage(contentsOf: imagesFolder.appendingPathComponent(name))
        imageCache[name] = img
        return img
    }

    /// ⌘V on the board: images become polaroids, multi-line text becomes a list, a line becomes a note.
    /// ⌘V on the board: whatever's on the clipboard becomes the right kind of card —
    /// copied image files or pictures → polaroids, several lines → a list, one line → a note.
    @discardableResult
    func paste(at point: CGPoint? = nil, from pb: NSPasteboard = .general) -> Bool {
        let spot = point ?? randomSpot()
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            var added = false
            for (i, u) in urls.enumerated() {
                added = addPhoto(fileURL: u, at: spot + CGSize(width: i * 18, height: i * 18)) || added
            }
            // Copied files that aren't images: don't paste their Finder icons instead.
            return added
        }
        if Self.hasPicture(pb), let img = NSImage(pasteboard: pb) {
            return addPhoto(image: img, at: spot)
        }
        if let s = pb.string(forType: .string), !s.trimmed.isEmpty {
            addText(s, at: spot)
            return true
        }
        return false
    }

    /// A real picture (screenshot, "Copy Image" in a browser) rather than rich text that
    /// happens to carry a rendered preview, like text copied from Pages or Word.
    static func hasPicture(_ pb: NSPasteboard) -> Bool {
        let types = Set(pb.types ?? [])
        let pictures: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]
        let richText: [NSPasteboard.PasteboardType] = [.rtf, .rtfd, NSPasteboard.PasteboardType("com.apple.flat-rtfd")]
        return pictures.contains(where: types.contains) && !richText.contains(where: types.contains)
    }

    func addText(_ s: String, at p: CGPoint) {
        let lines = s.split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .map { $0.replacingOccurrences(of: #"^([-*•]|\[ ?\]|\d+[.)])\s*"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        if lines.count > 1 {
            addList(lines: lines, at: p)
        } else if let line = lines.first {
            addNote(text: line, at: p)
        }
    }

    // MARK: - Editing

    private var textBeforeEditing = ""

    func beginEditing(_ id: UUID) {
        if editingID != id { endEditing() }
        textBeforeEditing = card(id)?.text ?? ""
        editingID = id
    }

    /// Leaves edit mode, tidying up: blank list rows vanish and blank cards are discarded.
    /// A note that mentions a date then offers to move into deadlines.
    func endEditing() {
        resignFocus?()
        confirmingRemoveID = nil
        datePromptID = nil
        selectedID = nil
        guard let id = editingID else { return }
        editingID = nil
        guard let i = index(of: id) else { return }
        var c = cards[i]
        if c.text != textBeforeEditing { c.datePromptDeclined = false }
        defer { if let c = card(id) { offerDeadline(for: c) } }
        c.items.removeAll { $0.text.trimmed.isEmpty }
        if c.kind == .deadlines {
            for j in c.items.indices where c.items[j].due == nil {
                applyParsedDue(&c.items[j])
            }
            c.items = Due.sorted(c.items)
        }
        let isEmpty: Bool = switch c.kind {
        case .note, .label: c.text.trimmed.isEmpty
        case .list, .deadlines: c.text.trimmed.isEmpty && c.items.isEmpty
        case .photo: false
        }
        if isEmpty {
            withAnimation(.easeOut(duration: 0.2)) { _ = cards.remove(at: i) }
            return
        }
        if c != cards[i] {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { cards[i] = c }
        }
        if c.kind == .note { tutorialEvent(.noteWritten) }
    }

    // MARK: - Walkthrough

    func startTutorial() {
        tutorialSawHide = false
        tutorialTargetID = nil
        tutorialItemID = nil
        tutorialStepDone = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { tutorialStep = .create }
    }

    func endTutorial() {
        withAnimation(.easeOut(duration: 0.25)) { tutorialStep = nil }
        if !ephemeral { UserDefaults.standard.set(true, forKey: "tutorialDone") }
    }

    func skipTutorialStep() { advanceTutorial() }

    /// Called whenever you do something; completes the current step if it's the thing it asked for.
    func tutorialEvent(_ event: TutorialEvent) {
        guard let step = tutorialStep, !tutorialStepDone else { return }
        if step == .hideAndReturn && event == .hidden { tutorialSawHide = true; return }
        guard event == step.trigger, step != .hideAndReturn || tutorialSawHide else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { tutorialStepDone = true }
        // A beat to see the check mark, then on to the next step.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard self?.tutorialStep == step else { return }
            self?.advanceTutorial()
        }
    }

    private func advanceTutorial() {
        guard let step = tutorialStep else { return }
        guard let next = TutorialStep(rawValue: step.rawValue + 1) else { endTutorial(); return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            tutorialStep = next
            tutorialStepDone = false
        }
    }

    // MARK: - Deadlines

    private func offerDeadline(for c: Card) {
        guard c.kind == .note, !c.done, !c.datePromptDeclined, Due.parse(c.text).due != nil else { return }
        withAnimation(.easeOut(duration: 0.2)) { datePromptID = c.id }
    }

    func declineDatePrompt(_ id: UUID) {
        update(id) { $0.datePromptDeclined = true }
        withAnimation(.easeOut(duration: 0.15)) { datePromptID = nil }
    }

    /// "Yes": the note becomes a dated row in the topmost deadlines card (or a new one in its place).
    func moveNoteToDeadlines(_ id: UUID) {
        guard let note = card(id), note.kind == .note else { return }
        let parsed = Due.parse(note.text)
        guard let due = parsed.due else { return }
        snapshot()
        let item = ListItem(text: parsed.text, done: note.done, due: due)
        datePromptID = nil
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            if let j = cards.lastIndex(where: { $0.kind == .deadlines }) {
                cards[j].items = Due.sorted(cards[j].items + [item])
                cards[j].doneAt = cards[j].isComplete ? cards[j].doneAt : nil
            } else {
                var list = Card(kind: .deadlines, x: note.x, y: note.y)
                list.items = [item]
                cards.append(list)
            }
            cards.removeAll { $0.id == id }
        }
        // If this was the walkthrough's note, keep pointing at it in its new home.
        if tutorialTargetID == id {
            tutorialTargetID = cards.last(where: { $0.kind == .deadlines })?.id
            tutorialItemID = item.id
        }
        flashItemID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard self?.flashItemID == item.id else { return }
            withAnimation(.easeOut(duration: 0.6)) { self?.flashItemID = nil }
        }
    }

    private func applyParsedDue(_ item: inout ListItem) {
        let parsed = Due.parse(item.text)
        if let due = parsed.due {
            item.text = parsed.text
            item.due = due
        }
    }

    /// Turns "essay fri" into "essay" due Friday. Called when you press Return on a row.
    func parseDue(in id: UUID, _ itemID: UUID) {
        update(id) { c in
            if let j = c.items.firstIndex(where: { $0.id == itemID }) { applyParsedDue(&c.items[j]) }
        }
    }

    func setDue(in id: UUID, _ itemID: UUID, to date: Date?) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            update(id) { c in
                guard let j = c.items.firstIndex(where: { $0.id == itemID }) else { return }
                c.items[j].due = date
                if editingID != id { c.items = Due.sorted(c.items) }
            }
        }
    }

    /// Re-sorts a deadline card after a beat, so you see the checkmark land before the row moves.
    private func resortSoon(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.editingID != id, let c = self.card(id), c.kind == .deadlines else { return }
            let sorted = Due.sorted(c.items)
            guard sorted != c.items else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { self.update(id) { $0.items = sorted } }
        }
    }

    @discardableResult
    func insertItem(in id: UUID, after itemID: UUID?) -> UUID {
        let item = ListItem(text: "")
        update(id) { c in
            if let itemID, let j = c.items.firstIndex(where: { $0.id == itemID }) {
                c.items.insert(item, at: j + 1)
            } else {
                c.items.append(item)
            }
        }
        return item.id
    }

    func removeItem(in id: UUID, _ itemID: UUID) {
        update(id) { $0.items.removeAll { $0.id == itemID } }
    }

    // MARK: - Actions

    func toggleDone(_ id: UUID) {
        guard let c = card(id) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
            update(id) {
                $0.done.toggle()
                $0.doneAt = $0.done ? Date() : nil
            }
        }
        if !c.done {
            Sound.done(soundsOn)
            tutorialEvent(.checked)
        }
    }

    func toggleItem(_ id: UUID, _ itemID: UUID) {
        guard let c = card(id), let item = c.items.first(where: { $0.id == itemID }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
            update(id) { c in
                if let j = c.items.firstIndex(where: { $0.id == itemID }) { c.items[j].done.toggle() }
                c.doneAt = c.isComplete ? Date() : nil
            }
        }
        if !item.done {
            Sound.done(soundsOn)
            tutorialEvent(.checked)
        }
        resortSoon(id)
    }

    func uncheckAll(_ id: UUID) {
        withAnimation { update(id) { c in for j in c.items.indices { c.items[j].done = false }; c.doneAt = nil } }
        resortSoon(id)
    }

    func bringToFront(_ id: UUID) {
        guard let i = index(of: id), i != cards.count - 1 else { return }
        let c = cards.remove(at: i)
        cards.append(c)
    }

    func duplicate(_ id: UUID) {
        guard var c = card(id) else { return }
        c.id = UUID()
        c.x += 18
        c.y += 18
        c.items = c.items.map { ListItem(text: $0.text, done: $0.done, due: $0.due) }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { cards.append(c) }
    }

    func remove(_ id: UUID) {
        snapshot()
        confirmingRemoveID = nil
        if editingID == id { editingID = nil; resignFocus?() }
        withAnimation(.easeIn(duration: 0.18)) { cards.removeAll { $0.id == id } }
        tutorialEvent(.removed)
    }

    /// Sweeps finished notes and checked list rows off the board (undoable with ⌘Z).
    func clearDone() {
        guard hasDone else { return }
        snapshot()
        endEditing()
        withAnimation(.easeInOut(duration: 0.3)) {
            cards = cards.compactMap { c in
                var c = c
                switch c.kind {
                case .note:
                    return c.done ? nil : c
                case .list, .deadlines:
                    let had = c.items.count
                    c.items.removeAll(where: \.done)
                    c.doneAt = nil
                    return (had > 0 && c.items.isEmpty) ? nil : c
                default:
                    return c
                }
            }
        }
    }

    private func snapshot() {
        undoStack.append(cards)
        if undoStack.count > 40 { undoStack.removeFirst() }
    }

    func undo() {
        guard let last = undoStack.popLast() else { NSSound.beep(); return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) { cards = last }
    }

    // MARK: - Helpers

    static func jpegData(_ image: NSImage, maxPixel: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxPixel / CGFloat(max(cg.width, cg.height)))
        let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    /// A filled-in board for offscreen snapshots.
    static func sampleCards() -> [Card] {
        var label = Card(kind: .label, x: 112, y: 96)
        label.text = "THIS WEEK"

        var hello = Card(kind: .note, x: 128, y: 205)
        hello.text = "double-click anywhere on the board to pin a new note"

        var list = Card(kind: .list, x: 338, y: 262)
        list.text = "how this works"
        list.items = [
            ListItem(text: "drag cards anywhere", done: true),
            ListItem(text: "click the boxes to check things off"),
            ListItem(text: "drop or paste photos onto the board"),
            ListItem(text: "hover a card and click × to remove it"),
            ListItem(text: "⌘H hides the board, ⇧⌘H brings it back"),
        ]

        var tip = Card(kind: .note, x: 136, y: 392)
        tip.text = "right-click the board for more — or a card to change its paper"

        var someday = Card(kind: .label, x: 330, y: 520)
        someday.text = "SOMEDAY"
        someday.tape = .red

        return [label, hello, list, tip, someday]
    }
}

enum Sound {
    static func done(_ enabled: Bool) {
        guard enabled, let s = NSSound(named: "Pop")?.copy() as? NSSound else { return }
        s.volume = 0.35
        s.play()
    }
}
