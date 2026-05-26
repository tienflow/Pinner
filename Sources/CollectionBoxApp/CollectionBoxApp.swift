import AppKit
import CollectionBox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private let store = CollectionStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — this is a menu-bar-only app
        NSApp.setActivationPolicy(.accessory)

        menuBarController = MenuBarController(store: store)
        menuBarController?.activate()
    }
}

// Entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
