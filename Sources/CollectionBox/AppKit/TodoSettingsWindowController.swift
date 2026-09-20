import AppKit
import SwiftUI

/// Compatibility forwarder: opens the unified Settings window at the Todo AI tab.
public final class TodoSettingsWindowController: NSObject {
    public static let shared = TodoSettingsWindowController()

    public func show() {
        SettingsWindowController.shared.show(tab: .todoAI)
    }
}