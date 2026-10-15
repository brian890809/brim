import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?
    #if DEBUG
    private var previewAccounts: ClaudeAccountsController?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        // Unit tests use injected providers; don't contact accounts or Keychain
        // from their host application's startup.
        guard NSClassFromString("XCTestCase") == nil else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PreviewClaudeAccounts") {
            let controller = ClaudeAccountsController(service: PreviewClaudeAccounts())
            previewAccounts = controller
            controller.showWindow()
            Task { await controller.refreshAccounts() }
            return
        }
        #endif

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
