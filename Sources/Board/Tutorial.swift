import SwiftUI

/// Things you can do on the board that the walkthrough listens for.
enum TutorialEvent {
    case noteCreated, noteWritten, checked, dragged, photoAdded, removed, hidden, shown
}

/// A learn-by-doing walkthrough: each step advances when you actually do the thing.
enum TutorialStep: Int, CaseIterable {
    case create, write, check, drag, photo, remove, hideAndReturn, finished

    /// Steps that count toward "Step n / total" (the closing note doesn't).
    static let total = TutorialStep.allCases.count - 1

    var trigger: TutorialEvent? {
        switch self {
        case .create: .noteCreated
        case .write: .noteWritten
        case .check: .checked
        case .drag: .dragged
        case .photo: .photoAdded
        case .remove: .removed
        case .hideAndReturn: .shown
        case .finished: nil
        }
    }
}

// MARK: - Anchors

/// Parts of the board the walkthrough points at. Cards publish where these are.
enum TutorialTarget: Hashable {
    case card, checkbox, remove
}

struct TutorialAnchorKey: PreferenceKey {
    static var defaultValue: [TutorialTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TutorialTarget: Anchor<CGRect>], nextValue: () -> [TutorialTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Lets the walkthrough find this view on the board while `active`.
    func tutorialAnchor(_ target: TutorialTarget, active: Bool) -> some View {
        // Merge with what's inside (a card contains its tick box), rather than replacing it.
        transformAnchorPreference(key: TutorialAnchorKey.self, value: .bounds) { all, anchor in
            if active { all[target] = anchor }
        }
    }
}

// MARK: - The layer drawn over the board

/// Hints drawn right where things happen — a ghost note to double-click, a pulse on the
/// tick box, a ghost card sliding away — plus one line of small print to skip or end.
struct TutorialLayer: View {
    @EnvironmentObject var store: BoardStore
    let targets: [TutorialTarget: CGRect]
    let size: CGSize

    var body: some View {
        if let step = store.tutorialStep {
            ZStack(alignment: .topLeading) {
                hints(for: step)
                    .opacity(store.tutorialStepDone ? 0 : 1)
                    .animation(.easeOut(duration: 0.25), value: store.tutorialStepDone)
                    .allowsHitTesting(false)
                    .id(step)
                    .transition(.opacity)

                if step == .finished {
                    Finale().position(x: size.width / 2, y: size.height * 0.45)
                }

                StepLine(step: step)
                    .position(x: size.width / 2, y: size.height - 18)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder private func hints(for step: TutorialStep) -> some View {
        switch step {
        case .create:
            let spot = emptySpot(CGSize(width: 166, height: 96))
            GhostNote()
                .position(spot)
            Callout(title: "Double-click anywhere to pin a note")
                .position(x: spot.x, y: spot.y + 70)

        case .write:
            if let card = targets[.card] {
                callout(below: card, title: "Type it, then press Return",
                        tip: "Mention a day — like “essay fri” — to add it to deadlines")
            }

        case .check:
            if let box = targets[.checkbox] {
                Pulse().position(x: box.midX, y: box.midY)
                callout(below: labelSpot(near: box), title: "Tick the box when it’s done",
                        tip: "Finished things fade out of focus")
            }

        case .drag:
            if let card = targets[.card] {
                DragGhost(rect: card)
                callout(below: card, title: "Drag it anywhere",
                        tip: "Grab bare metal to move the whole board")
            }

        case .photo:
            let zone = CGSize(width: 150, height: 172)
            let spot = emptySpot(zone)
            DropZone(size: zone).position(spot)
            Callout(title: "Drop a photo here — or press ⌘V", tip: "Click a photo to resize it from its handles")
                .position(x: spot.x, y: spot.y + zone.height / 2 + 26)

        case .remove:
            if let x = targets[.remove] {
                Pulse().position(x: x.midX, y: x.midY)
                callout(below: labelSpot(near: x), title: "Click × to remove a card")
            }

        case .hideAndReturn:
            Keys().position(emptySpot(CGSize(width: 250, height: 110)))

        case .finished:
            EmptyView()
        }
    }

    /// Labels go under the whole card so they don't cover its text — unless the card is tall
    /// (a long list), where that would be too far from the thing being pointed at.
    private func labelSpot(near r: CGRect) -> CGRect {
        guard let card = targets[.card], card.height < 220 else { return r }
        return card
    }

    /// A callout under something (or above it, near the bottom edge), kept on the board.
    private func callout(below r: CGRect, title: String, tip: String? = nil) -> some View {
        let below = r.maxY + 60 < size.height - 40
        let y = below ? r.maxY + 26 : r.minY - 26
        let x = min(max(r.midX, 130), size.width - 130)
        return Callout(title: title, tip: tip).position(x: x, y: y)
    }

    /// Somewhere open on the metal for a hint of size `s` (plus room for its label below):
    /// the spot nearest the middle that overlaps no card, or the least-covered one if the board is full.
    private func emptySpot(_ s: CGSize) -> CGPoint {
        let cardRects = store.cards.map { c -> CGRect in
            if c.id == store.tutorialFocusID, let r = targets[.card] { return r }
            let approx = Self.approxSize(of: c)
            return CGRect(x: c.x - approx.width / 2, y: c.y - approx.height / 2, width: approx.width, height: approx.height)
        }
        let need = CGSize(width: max(s.width, 240), height: s.height + 60)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.42)
        var best = center, bestScore = CGFloat.infinity
        for y in stride(from: need.height / 2 + 40, through: size.height - need.height / 2 - 40, by: 16) {
            for x in stride(from: need.width / 2 + 10, through: size.width - need.width / 2 - 10, by: 16) {
                let r = CGRect(x: x - need.width / 2, y: y - s.height / 2, width: need.width, height: need.height)
                let covered = cardRects.reduce(0) { $0 + $1.intersection(r).width * $1.intersection(r).height }
                let score = covered * 10 + hypot(x - center.x, y - center.y)
                if score < bestScore { bestScore = score; best = CGPoint(x: x, y: y) }
            }
        }
        return best
    }

    /// Rough on-board size of a card, for keeping hints off it.
    private static func approxSize(of c: Card) -> CGSize {
        let photoWidth = CGFloat(c.width ?? Double(PhotoCard.defaultWidth))
        return switch c.kind {
        case .note: CGSize(width: 166, height: 100)
        case .list: CGSize(width: 200, height: 60 + CGFloat(c.items.count) * 24)
        case .deadlines: CGSize(width: 236, height: 60 + CGFloat(c.items.count) * 46)
        case .label: CGSize(width: CGFloat(c.text.count) * 11 + 30, height: 30)
        case .photo: CGSize(width: photoWidth + 16, height: photoWidth * 0.75 + 36)
        }
    }
}

// MARK: - Pieces

private let ink = Color(white: 0.1)

/// A small dark label, the same ink as the board's other prompts.
/// Tutorial text is small print set straight onto the metal — no boxes — in the same quiet
/// gray as the board's own date and controls.
private let printInk = Color(white: 0.1).opacity(0.72)
private let printInkSoft = Color(white: 0.1).opacity(0.48)

extension View {
    /// A hairline of light under the letters, so the print reads on metal and paper alike.
    fileprivate func printedOnMetal() -> some View {
        shadow(color: .white.opacity(0.55), radius: 0, x: 0, y: 0.8)
    }
}

struct Callout: View {
    let title: String
    var tip: String? = nil

    var body: some View {
        VStack(spacing: 3) {
            Text(title).smallCaps().foregroundStyle(printInk)
            if let tip {
                Text(tip).font(Print.sans(Print.smallSize + 1.5)).foregroundStyle(printInkSoft)
            }
        }
        .multilineTextAlignment(.center)
        .printedOnMetal()
        .fixedSize()
    }
}

/// Repeating time in 0..<1 over `period` seconds.
private func phase(_ date: Date, period: Double, offset: Double = 0) -> Double {
    ((date.timeIntervalSinceReferenceDate + offset) / period).truncatingRemainder(dividingBy: 1)
}

/// Expanding rings around something to press.
struct Pulse: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            ZStack {
                ForEach(0..<2, id: \.self) { i in
                    let t = phase(ctx.date, period: 1.6, offset: Double(i) * 0.8)
                    Circle()
                        .stroke(ink, lineWidth: 1.4)
                        .frame(width: 16 + 30 * t, height: 16 + 30 * t)
                        .opacity(0.8 * (1 - t))
                }
                Circle().stroke(ink.opacity(0.8), lineWidth: 1.2).frame(width: 22, height: 22)
            }
        }
        .frame(width: 50, height: 50)
    }
}

/// A dashed outline of a note with a cursor double-clicking in the middle.
struct GhostNote: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = phase(ctx.date, period: 2.0)
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                    .frame(width: 166, height: 96)
                // Two quick ripples — a double-click — then a pause.
                ForEach([0.0, 0.16], id: \.self) { start in
                    let r = min(max((t - start) / 0.35, 0), 1)
                    Circle()
                        .stroke(ink, lineWidth: 1.2)
                        .frame(width: 6 + 26 * r, height: 6 + 26 * r)
                        .opacity(r > 0 && r < 1 ? 1 - r : 0)
                }
                Image(systemName: "cursorarrow")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(ink)
                    .shadow(color: .white.opacity(0.8), radius: 0.5)
                    .offset(x: 5, y: 8)
                    .scaleEffect(t < 0.05 || (t > 0.16 && t < 0.21) ? 0.88 : 1)
            }
        }
    }
}

/// A ghost of the card sliding off along a dotted path, with a cursor carrying it.
struct DragGhost: View {
    let rect: CGRect

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = phase(ctx.date, period: 2.2)
            let move = t < 0.15 ? 0 : min((t - 0.15) / 0.6, 1)
            let eased = move * move * (3 - 2 * move)
            let d = CGSize(width: 70 * eased, height: -36 * eased)
            let fade = t < 0.1 ? t / 0.1 : (t > 0.85 ? max(0, (1 - t) / 0.15) : 1)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: rect.midX, y: rect.midY))
                    p.addLine(to: CGPoint(x: rect.midX + 70, y: rect.midY - 36))
                }
                .stroke(ink.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                Rectangle()
                    .strokeBorder(ink.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX + d.width, y: rect.minY + d.height)
                    .opacity(fade)
                Image(systemName: "cursorarrow")
                    .font(.system(size: 15))
                    .foregroundStyle(ink)
                    .shadow(color: .white.opacity(0.8), radius: 0.5)
                    .offset(x: rect.midX + d.width, y: rect.midY + d.height)
                    .opacity(fade)
            }
        }
    }
}

/// A dashed, polaroid-shaped spot on the metal to drop a photo onto.
struct DropZone: View {
    let size: CGSize

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = phase(ctx.date, period: 2.4)
            let breathe = 0.5 + 0.5 * sin(t * 2 * .pi)
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.08 + 0.08 * breathe))
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .frame(width: size.width - 16, height: size.width - 16)
                    .offset(y: -(size.height - size.width) / 2 + 4)
                Image(systemName: "arrow.down")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(ink.opacity(0.7))
                    .offset(y: -18 + 6 * breathe)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// Printed keycaps: ⌘H to put it away, ⇧⌘H to bring it back.
struct Keys: View {
    var body: some View {
        VStack(spacing: 12) {
            row(["⌘", "H"], "Put it away")
            row(["⇧", "⌘", "H"], "Bring it back")
            Text("Or click the tab on the edge of your screen")
                .font(Print.sans(Print.smallSize + 1.5))
                .foregroundStyle(printInkSoft)
                .printedOnMetal()
        }
    }

    private func row(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { KeyCap(symbol: $0) }
            Text(label).smallCaps().foregroundStyle(printInk).printedOnMetal().padding(.leading, 6)
            Spacer(minLength: 0)
        }
        .frame(width: 210)
    }
}

struct KeyCap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(Print.sans(Print.bodySize, .medium))
            .foregroundStyle(ink)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(white: 0.97))
                    .shadow(color: .black.opacity(0.3), radius: 0, y: 1.5)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
            )
    }
}

struct Finale: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        VStack(spacing: 8) {
            Text("That’s it — it’s your board now.").font(Print.title).foregroundStyle(printInk)
            Text("Right-click the metal for lists and everything else.")
                .font(Print.sans(Print.smallSize + 1.5))
                .foregroundStyle(printInkSoft)
            Button("Done") { store.endTutorial() }
                .buttonStyle(.plain)
                .smallCaps()
                .foregroundStyle(printInk)
                .padding(.top, 6)
        }
        .printedOnMetal()
        .fixedSize()
    }
}

/// The only fixed piece: "STEP 2 / 7 · SKIP · END TUTORIAL" in small print.
struct StepLine: View {
    @EnvironmentObject var store: BoardStore
    let step: TutorialStep

    var body: some View {
        HStack(spacing: 10) {
            if store.tutorialStepDone {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                    .transition(.scale.combined(with: .opacity))
            }
            if step != .finished {
                Text("Step \(step.rawValue + 1) / \(TutorialStep.total)")
                Text("·")
                Button("Skip") { store.skipTutorialStep() }
                Text("·")
                Button("End tutorial") { store.endTutorial() }
            }
        }
        .buttonStyle(.plain)
        .smallCaps()
        .foregroundStyle(printInkSoft)
        .printedOnMetal()
        .fixedSize()
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: store.tutorialStepDone)
    }
}
