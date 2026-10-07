import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        // Unit tests use injected providers; don't contact accounts or Keychain
        // from their host application's startup.
        guard NSClassFromString("XCTestCase") == nil else { return }

        let previewOptions = NotchPreviewOptions()
        let controller = previewOptions.isActive
            ? NotchPreviewMode.makeWindowController(options: previewOptions)
            : NotchWindowController()
        notchController = controller
        controller.start()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        notchController?.expand()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}
