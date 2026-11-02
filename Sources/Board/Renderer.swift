import SwiftUI

/// Offscreen rendering for the app icon and for previewing the board without launching it.
@MainActor
enum Renderer {
    /// True while rendering offscreen: AppKit-backed views (mouse trackers) can't be drawn there.
    static var isRendering = false

    static func renderIcon(to path: String) {
        write(AppIconView(), size: CGSize(width: 1024, height: 1024), scale: 1, to: path)
    }

    /// A clean board for the README: a few notes, a list, and a deadlines card.
    static func screenshot(to path: String) {
        isRendering = true
        let store = BoardStore(ephemeral: true)
        store.cards.removeAll { $0.kind == .label && $0.text == "SOMEDAY" }
        if let i = store.cards.firstIndex(where: { $0.kind == .note }) {
            store.cards[i].done = true
        }
        var deadlines = Card(kind: .deadlines, x: 250, y: 640)
        deadlines.text = "Deadlines"
        deadlines.items = Due.sorted(["essay draft fri", "call mom tomorrow", "pay rent today", "submit form next week"].map {
            let parsed = Due.parse($0)
            return ListItem(text: parsed.text, due: parsed.due)
        })
        store.cards.append(deadlines)
        let view = BoardView()
            .environmentObject(store)
            .environmentObject(BoardController(store: store))
        write(view, size: CGSize(width: 480, height: 800), scale: 2, to: path)
    }

    static func snapshot(to path: String) {
        isRendering = true
        let store = BoardStore(ephemeral: true)
        store.cards[1].done = true
        store.cards[1].doneAt = Date()
        var deadlines = Card(kind: .deadlines, x: 250, y: 650)
        deadlines.text = "deadlines"
        deadlines.items = ["essay draft fri", "call mom tomorrow", "pay rent today", "submit form next week"].map { line in
            let parsed = Due.parse(line)
            return ListItem(text: parsed.text, due: parsed.due)
        }
        deadlines.items = Due.sorted(deadlines.items)
        for item in deadlines.items { print(item.text, "→", item.due.map { Due.describe($0, now: Date()).label } ?? "no date") }
        store.cards.removeLast()
        store.cards.append(deadlines)
        // A freshly written note that mentions a date, asking to join the deadlines.
        store.cards[3].text = "pay rent on the 15th"
        let promptNote = store.cards[3].id
        print("prompt note:", Due.parse(store.cards[3].text))
        // A resized photo.
        let sample = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { r in
            NSGradient(colors: [.systemTeal, .systemIndigo])!.draw(in: r, angle: 35)
            return true
        }
        store.cards.removeFirst()
        store.addPhoto(image: sample, at: CGPoint(x: 140, y: 140))
        store.update(store.cards.last!.id) { $0.width = 210; $0.text = "studio, nov" }
        store.selectedID = store.cards.last!.id
        if let d = store.cards.firstIndex(where: { $0.kind == .deadlines }) {
            store.cards[d].items[store.cards[d].items.count - 1].done = true
        }
        store.tutorialStep = TutorialStep(rawValue: Int(ProcessInfo.processInfo.environment["BOARD_STEP"] ?? "") ?? 2) ?? .check
        store.tutorialTargetID = promptNote
        // A row that just arrived from a note, still highlighted.
        store.flashItemID = deadlines.items[1].id
        let view = BoardView()
            .environmentObject(store)
            .environmentObject(BoardController(store: store))
        write(view, size: CGSize(width: 480, height: 760), scale: 2, to: path)
    }

    private static func write(_ view: some View, size: CGSize, scale: CGFloat, to path: String) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("render failed")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

struct AppIconView: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 186, style: .continuous)
        ZStack {
            AluminumSurface()
                .scaleEffect(1.6)
                .frame(width: 824, height: 824)
                .clipShape(shape)
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white, .white.opacity(0.3), .black.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 5
                ))
                .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 14)

            VStack(alignment: .leading, spacing: 30) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 22) {
                        Circle()
                            .fill(i == 0 ? Color(white: 0.15) : .clear)
                            .overlay(Circle().strokeBorder(Color(white: 0.15), lineWidth: 7))
                            .overlay(Image(systemName: "checkmark").font(.system(size: 26, weight: .black)).foregroundStyle(.white).opacity(i == 0 ? 1 : 0))
                            .frame(width: 46, height: 46)
                        Capsule().fill(Color(white: 0.15).opacity(i == 0 ? 0.3 : 0.75)).frame(width: [190, 230, 150][i], height: 14)
                    }
                }
            }
            .padding(.horizontal, 50)
            .padding(.top, 86)
            .padding(.bottom, 56)
            .background(
                Rectangle().fill(Color(red: 0.985, green: 0.982, blue: 0.972))
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 1, y: 3)
                    .shadow(color: .black.opacity(0.18), radius: 22, x: 8, y: 20)
            )
            .overlay(alignment: .top) { Magnet(size: 96).offset(x: 20, y: -36) }
            .rotationEffect(.degrees(-4))
            .offset(y: 24)
        }
        .frame(width: 1024, height: 1024)
    }
}
