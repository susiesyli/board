import AppKit

let arguments = CommandLine.arguments

MainActor.assumeIsolated {
    let app = NSApplication.shared

    // Build-time helpers: `Board --render-icon out.png`, `Board --snapshot out.png`
    if let i = arguments.firstIndex(of: "--render-icon"), i + 1 < arguments.count {
        Renderer.renderIcon(to: arguments[i + 1])
        exit(0)
    }
    if let i = arguments.firstIndex(of: "--screenshot"), i + 1 < arguments.count {
        Renderer.screenshot(to: arguments[i + 1])
        exit(0)
    }
    if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
        Renderer.snapshot(to: arguments[i + 1])
        exit(0)
    }

    // Before anything reads the saved board or settings.
    Rename.migrateFromAlloy()

    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
