import SwiftUI

enum CardKind: String, Codable {
    case note, list, label, photo, deadlines

    /// Kinds whose content is a list of checkable rows.
    var hasItems: Bool { self == .list || self == .deadlines }
}

/// Paper stocks for note & list cards — muted, print-shop colors rather than neon stickies.
enum Paper: String, Codable, CaseIterable, Identifiable {
    case white, cream, butter, blush, sky, sage, kraft, ink

    var id: String { rawValue }

    var name: String {
        switch self {
        case .white: "Bright White"
        case .cream: "Cream"
        case .butter: "Butter"
        case .blush: "Blush"
        case .sky: "Sky"
        case .sage: "Sage"
        case .kraft: "Kraft"
        case .ink: "Ink"
        }
    }

    var rgb: (Double, Double, Double) {
        switch self {
        case .white: (0.985, 0.982, 0.972)
        case .cream: (0.968, 0.942, 0.880)
        case .butter: (0.985, 0.925, 0.680)
        case .blush: (0.965, 0.850, 0.840)
        case .sky: (0.815, 0.880, 0.945)
        case .sage: (0.835, 0.875, 0.800)
        case .kraft: (0.790, 0.690, 0.545)
        case .ink: (0.115, 0.115, 0.125)
        }
    }

    var color: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }
    var nsColor: NSColor { NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
    var ink: Color { self == .ink ? Color(white: 0.93) : Color(red: 0.12, green: 0.12, blue: 0.13) }
}

/// Label-maker tape colors.
enum Tape: String, Codable, CaseIterable, Identifiable {
    case black, red, blue, green, white

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var rgb: (Double, Double, Double) {
        switch self {
        case .black: (0.10, 0.10, 0.11)
        case .red: (0.74, 0.12, 0.13)
        case .blue: (0.12, 0.28, 0.60)
        case .green: (0.10, 0.42, 0.28)
        case .white: (0.95, 0.95, 0.93)
        }
    }

    var color: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }
    var nsColor: NSColor { NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
    var ink: Color { self == .white ? Color(white: 0.12) : Color(white: 0.96) }
}

struct ListItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done = false
    var due: Date?
}

struct Card: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: CardKind
    var text = ""
    var items: [ListItem] = []
    var done = false
    var doneAt: Date?
    var paper: Paper = .white
    var tape: Tape = .black
    /// Center of the card, in board coordinates.
    var x: Double
    var y: Double
    var imageFile: String?
    /// Custom width set by resizing (photos); nil means the kind's default.
    var width: Double?
    var created = Date()
    /// You said "No" to moving this note into deadlines; don't ask again until its text changes.
    var datePromptDeclined = false

    init(kind: CardKind, x: Double, y: Double) {
        self.kind = kind
        self.x = x
        self.y = y
    }

    var isComplete: Bool {
        switch kind {
        case .list, .deadlines: !items.isEmpty && items.allSatisfy(\.done)
        default: done
        }
    }

    // Tolerant decoding so older board files keep loading as fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(CardKind.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        items = try c.decodeIfPresent([ListItem].self, forKey: .items) ?? []
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        paper = (try? c.decodeIfPresent(Paper.self, forKey: .paper)) ?? .white
        tape = (try? c.decodeIfPresent(Tape.self, forKey: .tape)) ?? .black
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 200
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 200
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        width = try c.decodeIfPresent(Double.self, forKey: .width)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        datePromptDeclined = try c.decodeIfPresent(Bool.self, forKey: .datePromptDeclined) ?? false
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Due dates for deadline cards: natural-language parsing, sorting and chip labels.
enum Due {
    enum Urgency { case overdue, today, soon, later }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Pulls a date out of text like "essay fri", "taxes by nov 15", "call mom tomorrow".
    /// Returns the text with the date words removed (unless that would leave nothing).
    static func parse(_ text: String) -> (text: String, due: Date?) {
        let ns = text as NSString
        guard let (range, date) = detect(text) else { return (text, nil) }
        var rest = ns.replacingCharacters(in: range, with: " ")
        rest = rest.replacingOccurrences(of: #"\s*(\b(by|due|on|before|until)\b|@|-)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        rest = rest.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmed
        return (rest.isEmpty ? text.trimmed : rest, date)
    }

    /// macOS's date detector, plus two phrasings it misses: "next week" and "the 15th".
    private static func detect(_ text: String) -> (NSRange, Date)? {
        let full = NSRange(location: 0, length: (text as NSString).length)
        if let m = detector?.matches(in: text, range: full).last, let date = m.date {
            return (m.range, date)
        }
        let cal = Calendar.current
        let noon = cal.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        if let r = text.range(of: #"\bnext week\b"#, options: [.regularExpression, .caseInsensitive]) {
            return (NSRange(r, in: text), cal.date(byAdding: .day, value: 7, to: noon)!)
        }
        let ordinal = try! NSRegularExpression(pattern: #"\b(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)\b"#, options: .caseInsensitive)
        if let m = ordinal.matches(in: text, range: full).last,
           let day = Int((text as NSString).substring(with: m.range(at: 1))), (1...31).contains(day) {
            // The next time that day of the month comes around (today counts).
            var month = cal.dateComponents([.year, .month], from: noon)
            for _ in 0..<3 {
                month.day = day
                if let d = cal.date(from: month), cal.component(.day, from: d) == day, d >= cal.startOfDay(for: Date()) {
                    return (m.range, d.addingTimeInterval(12 * 3600))
                }
                month.day = 1
                let next = cal.date(byAdding: .month, value: 1, to: cal.date(from: month)!)!
                month = cal.dateComponents([.year, .month], from: next)
            }
        }
        return nil
    }

    /// Open items first, soonest deadline first, undated after; finished items sink to the bottom.
    /// Stable, so items with equal dates keep their order.
    static func sorted(_ items: [ListItem]) -> [ListItem] {
        items.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.done != y.done { return !x.done }
            switch (x.due, y.due) {
            case let (dx?, dy?) where dx != dy: return dx < dy
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    static func days(until due: Date, from now: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: due)).day ?? 0
    }

    static func describe(_ due: Date, now: Date) -> (label: String, urgency: Urgency) {
        let d = days(until: due, from: now)
        switch d {
        case ..<0: return ("\(-d)D LATE", .overdue)
        case 0: return ("TODAY", .today)
        case 1: return ("TMRW", .soon)
        case 2...6: return (due.formatted(.dateTime.weekday(.abbreviated)).uppercased(), d <= 3 ? .soon : .later)
        default: return (due.formatted(.dateTime.month(.abbreviated).day()).uppercased(), .later)
        }
    }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGSize) -> CGPoint { CGPoint(x: a.x + b.width, y: a.y + b.height) }
}

/// Small colored dots for context-menu items.
enum Swatch {
    static func image(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }
}
