import Foundation

/// The app used to be called Alloy. On first launch as Board, bring over the saved board
/// (notes, photos) and settings (board position, style, tutorial progress) from the old name.
enum Rename {
    /// Named after the bundle ID so it can't collide with another app's "Board" folder.
    static let dataFolderName = "com.susiesyli.board"

    private static let oldBundleID = "com.susiesyli.alloy"
    private static let oldDataFolder = "Alloy"

    static func migrateFromAlloy() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromAlloy") else { return }

        if let old = defaults.persistentDomain(forName: oldBundleID) {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let from = base.appendingPathComponent(oldDataFolder, isDirectory: true)
        let to = base.appendingPathComponent(dataFolderName, isDirectory: true)
        if fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
            try? fm.moveItem(at: from, to: to)
        }

        defaults.set(true, forKey: "migratedFromAlloy")
    }
}
