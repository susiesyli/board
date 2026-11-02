import SwiftUI

enum CardField: Hashable {
    case title
    case item(UUID)
}

/// Printed-matter typography: Helvetica Neue, hairlines, tiny spaced capitals.
enum Print {
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Helvetica Neue", size: size).weight(weight)
    }

    static let red = Color(red: 0.82, green: 0.16, blue: 0.12)

    // The type scale — every piece of text on the board uses one of these four sizes.
    static let titleSize: CGFloat = 14
    static let bodySize: CGFloat = 11.5
    static let numeralSize: CGFloat = 18
    static let smallSize: CGFloat = 7.5

    static var title: Font { sans(titleSize) }
    static var body: Font { sans(bodySize) }
    static var numeral: Font { sans(numeralSize, .light) }
}

extension View {
    /// The small print on a poster: dates, counts, labels, controls.
    func smallCaps(tracking: CGFloat = 1.2) -> some View {
        self.font(Print.sans(Print.smallSize, .medium)).tracking(tracking).textCase(.uppercase)
    }
}

/// Wraps every kind of card with the shared behavior: dragging, lifting,
/// double-click to edit, right-click menu, and the hover × to remove.
struct CardView: View {
    @EnvironmentObject var store: BoardStore
    let card: Card
    let boardSize: CGSize

    @State private var dragStart: CGPoint?
    @State private var hovering = false
    @FocusState private var focus: CardField?

    private var lifted: Bool { store.draggingID == card.id }
    private var editing: Bool { store.editingID == card.id }
    private var confirming: Bool { store.confirmingRemoveID == card.id }
    /// The walkthrough is pointing at this card.
    private var tutorialFocus: Bool { store.tutorialFocusID == card.id }
    private var showRemove: Bool {
        (hovering || editing || confirming || (tutorialFocus && store.tutorialStep == .remove)) && !lifted
    }

    var body: some View {
        content
            .contentShape(Rectangle())
            .tutorialAnchor(.card, active: tutorialFocus)
            .onTapGesture(count: 2) { store.beginEditing(card.id) }
            .onTapGesture { store.selectedID = card.kind == .photo ? card.id : nil }
            .gesture(drag)
            .contextMenu { CardMenu(card: card) }
            .overlay(alignment: .topTrailing) {
                RemoveControl(cardID: card.id, confirming: confirming)
                    .tutorialAnchor(.remove, active: tutorialFocus)
                    .offset(x: 7, y: -7)
                    .opacity(showRemove ? 1 : 0)
                    .allowsHitTesting(showRemove)
            }
            .overlay(alignment: .bottom) {
                if store.datePromptID == card.id && !lifted {
                    DatePrompt(card: card)
                        .offset(y: 12)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .scaleEffect(lifted ? 1.03 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: lifted)
            .position(displayPoint)
            .onChange(of: editing) { _, now in if now { focusFirstField() } }
            .onAppear { if editing { focusFirstField() } }
    }

    @ViewBuilder private var content: some View {
        switch card.kind {
        case .note: NoteCard(card: card, editing: editing, lifted: lifted, focus: $focus)
        case .list: ListCard(card: card, editing: editing, lifted: lifted, focus: $focus)
        case .deadlines: DeadlineCard(card: card, editing: editing, lifted: lifted, focus: $focus)
        case .label: LabelTape(card: card, editing: editing, lifted: lifted, focus: $focus)
        case .photo: PhotoCard(card: card, editing: editing, lifted: lifted, focus: $focus)
        }
    }

    /// Cards can hang a little off the edge (like real ones) but never disappear.
    private var displayPoint: CGPoint {
        CGPoint(
            x: min(max(card.x, 24), max(24, boardSize.width - 24)),
            y: min(max(card.y, 24), max(24, boardSize.height - 20))
        )
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("board"))
            .onChanged { v in
                if dragStart == nil {
                    dragStart = displayPoint
                    if store.editingID != nil && store.editingID != card.id { store.endEditing() }
                    store.confirmingRemoveID = nil
                    store.selectedID = card.kind == .photo ? card.id : nil
                    store.bringToFront(card.id)
                    store.draggingID = card.id
                }
                guard let s = dragStart else { return }
                let p = s + v.translation
                store.update(card.id) { $0.x = p.x; $0.y = p.y }
            }
            .onEnded { _ in
                dragStart = nil
                store.draggingID = nil
                let p = displayPoint
                store.update(card.id) { $0.x = p.x; $0.y = p.y }
                store.tutorialEvent(.dragged)
            }
    }

    private func focusFirstField() {
        let target: CardField = {
            guard card.kind.hasItems, !card.text.isEmpty, let last = card.items.last else { return .title }
            return .item(last.id)
        }()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { focus = target }
    }
}

/// A small × on the card's corner; clicking it asks "Remove? Yes / No" in place.
struct RemoveControl: View {
    @EnvironmentObject var store: BoardStore
    let cardID: UUID
    let confirming: Bool

    var body: some View {
        Group {
            if confirming {
                HStack(spacing: 10) {
                    Text("Remove?")
                    Button("Yes ↩") { store.remove(cardID) }
                        .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                    Button("No") { store.confirmingRemoveID = nil }
                }
                .buttonStyle(.plain)
                .smallCaps()
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(Capsule().fill(Color(white: 0.1)))
                .fixedSize()
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            } else {
                Button { store.confirmingRemoveID = cardID } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color(white: 0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .animation(.easeOut(duration: 0.15), value: confirming)
    }
}

/// Shown under a note that mentions a date: "Add to deadlines — Fri 6?  Yes  No".
struct DatePrompt: View {
    @EnvironmentObject var store: BoardStore
    let card: Card

    var body: some View {
        HStack(spacing: 10) {
            if let due = Due.parse(card.text).due {
                Text("Add to deadlines — \(due.formatted(.dateTime.weekday(.abbreviated).day()))?")
            }
            Button("Yes ↩") { store.moveNoteToDeadlines(card.id) }
                .foregroundStyle(Color(red: 1, green: 0.88, blue: 0.45))
            Button("No") { store.declineDatePrompt(card.id) }
        }
        .buttonStyle(.plain)
        .smallCaps()
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Capsule().fill(Color(white: 0.1)))
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .fixedSize()
    }
}

// MARK: - Shared pieces

/// A sheet of matte paper lying flat on the metal; it only casts a real shadow when lifted.
struct PaperSheet: View {
    var paper: Paper
    var lifted: Bool

    var body: some View {
        Rectangle()
            .fill(paper.color)
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
            .shadow(color: .black.opacity(lifted ? 0.14 : 0.2), radius: lifted ? 2 : 0.4, x: 0, y: lifted ? 2 : 0.5)
            .shadow(color: .black.opacity(lifted ? 0.24 : 0.07), radius: lifted ? 14 : 2, x: lifted ? 4 : 0.6, y: lifted ? 12 : 1.2)
    }
}

/// A hairline tick box, filled in when done — like a printed form.
struct CheckBox: View {
    var done: Bool
    var paper: Paper
    var size: CGFloat = 10
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle().strokeBorder(paper.ink.opacity(done ? 0.85 : 0.55), lineWidth: 0.8)
                if done {
                    Rectangle().fill(paper.ink.opacity(0.85)).padding(2.4)
                }
            }
            .frame(width: size, height: size)
            .padding(3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-3)
    }
}

struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

struct Hairline: View {
    var color: Color
    var dashed = false

    var body: some View {
        HLine()
            .stroke(color, style: StrokeStyle(lineWidth: dashed ? 0.6 : 0.7, dash: dashed ? [2, 2] : []))
            .frame(height: 1)
    }
}

/// A small text button in the card's small print, e.g. "+ ADD".
struct PrintButton: View {
    var title: String
    var color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) { Text(title).smallCaps() }
            .buttonStyle(.plain)
            .foregroundStyle(color)
    }
}

/// Finished things drift out of focus into a soft gray smudge; hover to read them again.
struct DoneBlur: ViewModifier {
    let done: Bool
    var radius: CGFloat = 1.6
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .blur(radius: done && !hovering ? radius : 0)
            .opacity(done ? (hovering ? 0.55 : 0.45) : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.35), value: done)
            .animation(.easeOut(duration: 0.2), value: hovering)
    }
}

extension View {
    func doneBlur(_ done: Bool, radius: CGFloat = 1.6) -> some View {
        modifier(DoneBlur(done: done, radius: radius))
    }
}

// MARK: - Note

struct NoteCard: View {
    @EnvironmentObject var store: BoardStore
    let card: Card
    let editing: Bool
    let lifted: Bool
    var focus: FocusState<CardField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CheckBox(done: card.done, paper: card.paper) { store.toggleDone(card.id) }
                    .tutorialAnchor(.checkbox, active: store.tutorialFocusID == card.id)
                Spacer()
                Text(card.created, format: .dateTime.day(.twoDigits).month(.abbreviated))
                    .smallCaps()
                    .foregroundStyle(card.paper.ink.opacity(0.45))
            }
            Group {
                if editing {
                    TextField("what needs doing?", text: store.textBinding(card.id), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...12)
                        .focused(focus, equals: .title)
                        .onSubmit { store.endEditing() }
                } else {
                    Text(card.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .doneBlur(card.done)
                }
            }
            .font(Print.body)
            .lineSpacing(1)
            .foregroundStyle(card.paper.ink)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
        }
        .padding(14)
        .frame(width: 166)
        .background(PaperSheet(paper: card.paper, lifted: lifted))
    }
}

// MARK: - List

struct ListCard: View {
    @EnvironmentObject var store: BoardStore
    let card: Card
    let editing: Bool
    let lifted: Bool
    var focus: FocusState<CardField?>.Binding

    private var doneCount: Int { card.items.filter(\.done).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editing || !card.text.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    if editing {
                        TextField("List", text: store.textBinding(card.id))
                            .textFieldStyle(.plain)
                            .focused(focus, equals: .title)
                            .onSubmit { focusItem(card.items.first?.id ?? store.insertItem(in: card.id, after: nil)) }
                    } else {
                        Text(card.text)
                    }
                    Spacer(minLength: 6)
                    count
                }
                .font(Print.title)
                .tracking(-0.2)
                .padding(.bottom, 8)
                Hairline(color: card.paper.ink.opacity(0.85))
                    .padding(.bottom, 4)
            }

            ForEach(card.items) { item in
                HStack(alignment: .top, spacing: 9) {
                    CheckBox(done: item.done, paper: card.paper) { store.toggleItem(card.id, item.id) }
                        .tutorialAnchor(.checkbox, active: store.tutorialCheckItemID(in: card) == item.id)
                        .padding(.top, 2)
                    if editing {
                        TextField("", text: store.itemBinding(card.id, item.id), axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...6)
                            .focused(focus, equals: .item(item.id))
                            .onSubmit { submit(item) }
                    } else {
                        Text(item.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .doneBlur(item.done, radius: 1.4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }

            if editing {
                PrintButton(title: "+ Add", color: card.paper.ink.opacity(0.45)) {
                    focusItem(store.insertItem(in: card.id, after: nil))
                }
                .padding(.top, 6)
            } else if card.text.isEmpty && !card.items.isEmpty {
                HStack { Spacer(); count }.padding(.top, 4)
            }
        }
        .font(Print.body)
        .foregroundStyle(card.paper.ink)
        .padding(14)
        .frame(width: 200, alignment: .leading)
        .background(PaperSheet(paper: card.paper, lifted: lifted))
    }

    private var count: some View {
        Text("\(doneCount) / \(card.items.count)")
            .smallCaps()
            .foregroundStyle(card.paper.ink.opacity(0.45))
    }

    private func submit(_ item: ListItem) {
        let current = store.card(card.id)?.items.first { $0.id == item.id }?.text ?? ""
        if current.trimmed.isEmpty {
            // Return on an empty row finishes the list, like Reminders.
            store.removeItem(in: card.id, item.id)
            store.endEditing()
        } else {
            focusItem(store.insertItem(in: card.id, after: item.id))
        }
    }

    private func focusItem(_ id: UUID) {
        DispatchQueue.main.async { focus.wrappedValue = .item(id) }
    }
}

// MARK: - Deadlines

/// A printed events-calendar poster that keeps itself sorted, soonest first.
/// Type the date right into the row ("essay fri", "taxes nov 15") or click the date.
struct DeadlineCard: View {
    @EnvironmentObject var store: BoardStore
    let card: Card
    let editing: Bool
    let lifted: Bool
    var focus: FocusState<CardField?>.Binding

    @State private var pickingID: UUID?

    static let red = Print.red

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    if editing {
                        TextField("Deadlines", text: store.textBinding(card.id))
                            .textFieldStyle(.plain)
                            .focused(focus, equals: .title)
                            .onSubmit { focusItem(card.items.first?.id ?? store.insertItem(in: card.id, after: nil)) }
                    } else {
                        Text(card.text.isEmpty ? "Deadlines" : card.text)
                    }
                    Spacer(minLength: 6)
                    Text(ctx.date, format: .dateTime.month(.wide).year())
                        .smallCaps()
                        .foregroundStyle(card.paper.ink.opacity(0.45))
                }
                .font(Print.title)
                .tracking(-0.2)
                .padding(.bottom, 8)
                Hairline(color: card.paper.ink.opacity(0.85))

                ForEach(Array(card.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Hairline(color: card.paper.ink.opacity(0.3), dashed: true) }
                    row(item, now: ctx.date)
                }

                if editing {
                    PrintButton(title: "+ Add  ·  type a date like “fri” or “nov 15”", color: card.paper.ink.opacity(0.45)) {
                        focusItem(store.insertItem(in: card.id, after: card.items.last?.id))
                    }
                    .padding(.top, 8)
                }
            }
        }
        .font(Print.body)
        .foregroundStyle(card.paper.ink)
        .padding(14)
        .frame(width: 236, alignment: .leading)
        .background(PaperSheet(paper: card.paper, lifted: lifted))
    }

    private func row(_ item: ListItem, now: Date) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // The date and the task blur out together; the tick box stays sharp.
            HStack(alignment: .center, spacing: 12) {
                Button { pickingID = item.id } label: {
                    DateBlock(due: item.due, done: item.done, now: now, ink: card.paper.ink)
                }
                .buttonStyle(.plain)
                .help(item.due.map { $0.formatted(date: .complete, time: .omitted) } ?? "Set a deadline")
                .popover(isPresented: Binding(
                    get: { pickingID == item.id },
                    set: { if !$0 { pickingID = nil } }
                ), arrowEdge: .leading) {
                    DuePicker(initial: item.due) { date in
                        store.setDue(in: card.id, item.id, to: date)
                        pickingID = nil
                    }
                }

                if editing {
                    TextField("task + when, e.g. essay fri", text: store.itemBinding(card.id, item.id), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused(focus, equals: .item(item.id))
                        .onSubmit { submit(item) }
                } else {
                    Text(item.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .doneBlur(item.done && !editing, radius: 1.4)

            CheckBox(done: item.done, paper: card.paper) { store.toggleItem(card.id, item.id) }
                .tutorialAnchor(.checkbox, active: store.tutorialCheckItemID(in: card) == item.id)
        }
        .padding(.vertical, 6)
        // A swipe of highlighter on a row that just arrived from a note.
        .background(
            Rectangle()
                .fill(Color(red: 1, green: 0.9, blue: 0.35).opacity(store.flashItemID == item.id ? 0.55 : 0))
                .padding(.horizontal, -6)
        )
    }

    private func submit(_ item: ListItem) {
        let current = store.card(card.id)?.items.first { $0.id == item.id }?.text ?? ""
        if current.trimmed.isEmpty {
            store.removeItem(in: card.id, item.id)
            store.endEditing()
        } else {
            store.parseDue(in: card.id, item.id)
            focusItem(store.insertItem(in: card.id, after: item.id))
        }
    }

    private func focusItem(_ id: UUID) {
        DispatchQueue.main.async { focus.wrappedValue = .item(id) }
    }
}

/// The big thin day numeral with a tiny label under it — like the dates on an events poster.
/// Red when it's due today or late.
struct DateBlock: View {
    let due: Date?
    let done: Bool
    let now: Date
    let ink: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(digits)
                .font(Print.numeral)
                .monospacedDigit()
                .tracking(-0.5)
            Text(label).smallCaps()
        }
        .foregroundStyle(color)
        .frame(width: 32, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var days: Int? { due.map { Due.days(until: $0, from: now) } }

    private var digits: String {
        guard let due else { return "—" }
        return due.formatted(.dateTime.day(.twoDigits))
    }

    private var label: String {
        guard let due, let d = days else { return "No date" }
        switch d {
        case ..<0: return "Late"
        case 0: return "Today"
        case 1: return "Tmrw"
        case 2...6: return due.formatted(.dateTime.weekday(.abbreviated))
        default: return due.formatted(.dateTime.month(.abbreviated))
        }
    }

    private var color: Color {
        if done { return ink.opacity(0.3) }
        guard let d = days else { return ink.opacity(0.3) }
        return d <= 0 ? Print.red : ink
    }
}

struct DuePicker: View {
    let initial: Date?
    let onSet: (Date?) -> Void
    @State private var date: Date

    init(initial: Date?, onSet: @escaping (Date?) -> Void) {
        self.initial = initial
        self.onSet = onSet
        let fallback = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        _date = State(initialValue: initial ?? fallback.addingTimeInterval(12 * 3600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .onChange(of: date) { _, d in onSet(d) }
            HStack(spacing: 6) {
                quick("Today", days: 0)
                quick("Tomorrow", days: 1)
                quick("Next week", days: 7)
                Spacer()
                if initial != nil {
                    Button("Clear") { onSet(nil) }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 250)
    }

    private func quick(_ title: String, days: Int) -> some View {
        Button(title) {
            let start = Calendar.current.startOfDay(for: Date())
            onSet(Calendar.current.date(byAdding: .day, value: days, to: start)!.addingTimeInterval(12 * 3600))
        }
    }
}

// MARK: - Label tape

/// Embossed label-maker tape — great for headings like "TODAY" or "SOMEDAY".
struct LabelTape: View {
    @EnvironmentObject var store: BoardStore
    let card: Card
    let editing: Bool
    let lifted: Bool
    var focus: FocusState<CardField?>.Binding

    var body: some View {
        Group {
            if editing {
                TextField("LABEL", text: store.textBinding(card.id, uppercase: true))
                    .textFieldStyle(.plain)
                    .focused(focus, equals: .title)
                    .onSubmit { store.endEditing() }
                    .frame(width: max(70, CGFloat(card.text.count) * 11 + 12))
            } else {
                Text(card.text.uppercased())
            }
        }
        .font(.system(size: Print.bodySize, weight: .heavy, design: .rounded))
        .tracking(2.2)
        .foregroundStyle(card.tape.ink.opacity(0.92))
        // Raised letters: lit from above, shadowed below.
        .shadow(color: .white.opacity(card.tape == .white ? 0.6 : 0.22), radius: 0, x: 0, y: -0.6)
        .shadow(color: .black.opacity(0.55), radius: 0, x: 0, y: 0.9)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Rectangle()
                .fill(card.tape.color)
                .overlay(LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.26), location: 0),
                        .init(color: .white.opacity(0.05), location: 0.45),
                        .init(color: .black.opacity(0.18), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
                .shadow(color: .black.opacity(lifted ? 0.18 : 0.3), radius: lifted ? 2 : 0.6, x: 0, y: lifted ? 2 : 0.8)
                .shadow(color: .black.opacity(lifted ? 0.25 : 0.1), radius: lifted ? 12 : 3, x: lifted ? 4 : 1, y: lifted ? 12 : 2.5)
        )
    }
}

// MARK: - Photo

/// A polaroid with a small printed caption. Click it to select it, then drag any of the
/// eight handles to resize — like a picture in Pages. Pinching on the trackpad works too.
struct PhotoCard: View {
    @EnvironmentObject var store: BoardStore
    let card: Card
    let editing: Bool
    let lifted: Bool
    var focus: FocusState<CardField?>.Binding

    @State private var hovering = false
    @State private var resizeStart: (width: CGFloat, frame: CGRect)?
    @State private var pinchStart: CGFloat?

    static let defaultWidth: CGFloat = 150
    static let widthRange: ClosedRange<CGFloat> = 80...560

    private var width: CGFloat { CGFloat(card.width ?? Self.defaultWidth) }
    private var selected: Bool { store.selectedID == card.id && !lifted }

    private var ratio: CGFloat {
        guard let img = store.image(for: card) else { return 1 }
        return min(max(img.size.height / max(img.size.width, 1), 0.62), 1.4)
    }

    /// The whole polaroid's size for a given photo width (frame padding + caption strip).
    private func cardSize(_ w: CGFloat) -> CGSize {
        CGSize(width: w + 16, height: w * ratio + 8 + 6 + 18 + 4)
    }

    var body: some View {
        polaroid
            .overlay {
                if selected {
                    SelectionHandles(onDrag: resize, onEnd: { resizeStart = nil })
                }
            }
            .simultaneousGesture(pinch)
            .onHover { hovering = $0 }
    }

    /// Resize from a handle: the photo keeps its shape, the opposite side stays put,
    /// and a side handle keeps the other axis centered.
    private func resize(from edges: Edge.Set, by t: CGSize) {
        if resizeStart == nil {
            let s = cardSize(width)
            resizeStart = (width, CGRect(x: card.x - s.width / 2, y: card.y - s.height / 2, width: s.width, height: s.height))
        }
        guard let start = resizeStart else { return }
        // How much wider the pull asks for, along whichever axes this handle moves.
        var pulls: [CGFloat] = []
        if edges.contains(.trailing) { pulls.append(t.width) }
        if edges.contains(.leading) { pulls.append(-t.width) }
        if edges.contains(.bottom) { pulls.append(t.height / ratio) }
        if edges.contains(.top) { pulls.append(-t.height / ratio) }
        let delta = pulls.reduce(0, +) / CGFloat(max(pulls.count, 1))
        let w = min(max(start.width + delta, Self.widthRange.lowerBound), Self.widthRange.upperBound)
        let s = cardSize(w)
        let f = start.frame
        let x = edges.contains(.trailing) ? f.minX + s.width / 2 : edges.contains(.leading) ? f.maxX - s.width / 2 : f.midX
        let y = edges.contains(.bottom) ? f.minY + s.height / 2 : edges.contains(.top) ? f.maxY - s.height / 2 : f.midY
        store.update(card.id) {
            $0.width = Double(w)
            $0.x = x
            $0.y = y
        }
    }

    /// Trackpad pinch scales around the photo's center.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchStart == nil { pinchStart = width }
                guard let start = pinchStart else { return }
                let w = min(max(start * v.magnification, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                store.update(card.id) { $0.width = Double(w) }
            }
            .onEnded { _ in pinchStart = nil }
    }

    private var polaroid: some View {
        VStack(spacing: 6) {
            photo
            Group {
                if editing {
                    TextField("caption", text: store.textBinding(card.id))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .focused(focus, equals: .title)
                        .onSubmit { store.endEditing() }
                } else {
                    Text(card.text).lineLimit(2).doneBlur(card.done, radius: 1.2)
                }
            }
            .smallCaps()
            .foregroundStyle(Color(white: 0.2))
            .frame(width: width, height: 18)
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .background(PaperSheet(paper: .white, lifted: lifted))
    }

    @ViewBuilder private var photo: some View {
        if let img = store.image(for: card) {
            let faded = card.done && !hovering
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: width * ratio)
                // Finished: out of focus and nearly colorless, blurred inside the frame.
                .blur(radius: faded ? 4 : 0, opaque: true)
                .saturation(card.done ? 0.15 : 1)
                .opacity(card.done ? 0.75 : 1)
                .clipped()
                .animation(.easeOut(duration: 0.35), value: faded)
        } else {
            Rectangle()
                .fill(Color(white: 0.85))
                .frame(width: width, height: width)
        }
    }
}

/// A thin outline with eight square handles around a selected photo — corners and
/// edge midpoints, like Pages. Each handle has a generous grab area.
struct SelectionHandles: View {
    let onDrag: (Edge.Set, CGSize) -> Void
    let onEnd: () -> Void

    private static let handles: [(edges: Edge.Set, at: UnitPoint)] = [
        ([.top, .leading], .topLeading), (.top, .top), ([.top, .trailing], .topTrailing),
        (.trailing, .trailing), ([.bottom, .trailing], .bottomTrailing), (.bottom, .bottom),
        ([.bottom, .leading], .bottomLeading), (.leading, .leading),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .stroke(Color(white: 0.1).opacity(0.85), lineWidth: 1)
                    .allowsHitTesting(false)
                ForEach(0..<Self.handles.count, id: \.self) { i in
                    let h = Self.handles[i]
                    HandleSquare(edges: h.edges)
                        .position(x: h.at.x * geo.size.width, y: h.at.y * geo.size.height)
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("board"))
                                .onChanged { onDrag(h.edges, $0.translation) }
                                .onEnded { _ in onEnd() }
                        )
                }
            }
        }
    }
}

struct HandleSquare: View {
    let edges: Edge.Set

    var body: some View {
        Rectangle()
            .fill(Color.white)
            .overlay(Rectangle().strokeBorder(Color(white: 0.1).opacity(0.85), lineWidth: 1))
            .frame(width: 8, height: 8)
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onHover { inside in
                let cursor = ResizeHandles.cursor(for: edges)
                inside ? cursor.push() : NSCursor.pop()
            }
    }
}

// MARK: - Context menu

struct CardMenu: View {
    @EnvironmentObject var store: BoardStore
    let card: Card

    var body: some View {
        if card.kind == .note || card.kind == .photo {
            Button(card.done ? "Mark as Not Done" : "Mark as Done") { store.toggleDone(card.id) }
        }
        if card.kind.hasItems && card.items.contains(where: \.done) {
            Button("Uncheck All") { store.uncheckAll(card.id) }
        }
        Button(card.kind == .photo ? "Edit Caption" : "Edit") { store.beginEditing(card.id) }
        if card.kind == .photo && card.width != nil {
            Button("Original Size") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { store.update(card.id) { $0.width = nil } }
            }
        }

        if card.kind == .note || card.kind.hasItems {
            Menu("Paper") {
                ForEach(Paper.allCases) { p in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { store.update(card.id) { $0.paper = p } }
                    } label: {
                        Label { Text(p.name) } icon: { Image(nsImage: Swatch.image(p.nsColor)) }
                    }
                }
            }
        }
        if card.kind == .label {
            Menu("Tape") {
                ForEach(Tape.allCases) { t in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { store.update(card.id) { $0.tape = t } }
                    } label: {
                        Label { Text(t.name) } icon: { Image(nsImage: Swatch.image(t.nsColor)) }
                    }
                }
            }
        }
        Button("Bring to Front") { withAnimation { store.bringToFront(card.id) } }
        Button("Duplicate") { store.duplicate(card.id) }
        Divider()
        Button("Remove…") { store.confirmingRemoveID = card.id }
    }
}
