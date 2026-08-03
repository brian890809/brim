import AppKit
import QuartzCore
import SwiftUI

private final class NotchSurfacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class NotchSurfaceHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class NotchWindowController: NSObject {
    private static let surfaceLevel = NSWindow.Level(
        rawValue: NSWindow.Level.statusBar.rawValue + 2
    )

    private let usageStore: UsageStore
    private let claudeStore: ClaudeUsageStore
    private let presentation: NotchPresentationModel

    private var surfacePanel: NSPanel!
    private var currentGeometry: NotchGeometry?
    private var isExpanded = false
    private var transitionGeneration = 0
    private var transitionTask: Task<Void, Never>?

    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var notificationTokens: [NSObjectProtocol] = []

    override convenience init() {
        self.init(
            usageStore: UsageStore(),
            claudeStore: ClaudeUsageStore(),
            presentation: NotchPresentationModel()
        )
    }

    init(
        usageStore: UsageStore,
        claudeStore: ClaudeUsageStore,
        presentation: NotchPresentationModel
    ) {
        self.usageStore = usageStore
        self.claudeStore = claudeStore
        self.presentation = presentation
        super.init()

        configurePanel()
        observeScreenChanges()
    }

    deinit {
        transitionTask?.cancel()
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    func start() {
        reposition()
        surfacePanel.orderFrontRegardless()
        claudeStore.refresh()
        Task { await usageStore.refreshIfStale() }
    }

    func expand() {
        setExpanded(true)
    }

    func collapse() {
        setExpanded(false)
    }

    private func configurePanel() {
        surfacePanel = NotchSurfacePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        surfacePanel.backgroundColor = .clear
        surfacePanel.isOpaque = false
        surfacePanel.hasShadow = false
        surfacePanel.hidesOnDeactivate = false
        surfacePanel.isReleasedWhenClosed = false
        surfacePanel.isMovable = false
        surfacePanel.isFloatingPanel = true
        surfacePanel.becomesKeyOnlyIfNeeded = true
        surfacePanel.canHide = false
        surfacePanel.isRestorable = false
        surfacePanel.level = Self.surfaceLevel
        surfacePanel.animationBehavior = .none
        surfacePanel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]

        let hostingView = NotchSurfaceHostingView(
            rootView: NotchSurfaceView(
                usageStore: usageStore,
                claudeStore: claudeStore,
                presentation: presentation,
                onRefresh: { [weak self] in self?.refreshAll() },
                onOpenCodex: { [weak self] in self?.usageStore.openCodex() },
                onExpand: { [weak self] in self?.expand() },
                onClose: { [weak self] in self?.collapse() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )
        hostingView.sizingOptions = []
        surfacePanel.contentView = hostingView
        surfacePanel.contentMinSize = .zero
        surfacePanel.minSize = .zero
    }

    private func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard
            expanded != isExpanded,
            let geometry = currentGeometry
        else {
            return
        }

        isExpanded = expanded
        transitionGeneration += 1
        let generation = transitionGeneration
        transitionTask?.cancel()

        if expanded {
            refreshAllIfStale()
            surfacePanel.orderFrontRegardless()
            surfacePanel.makeKey()
            installEventMonitors()
        } else {
            removeEventMonitors()
            surfacePanel.resignKey()
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let destination = expanded
            ? geometry.expandedSurfaceFrame
            : geometry.compactSurfaceFrame

        guard animated, !reduceMotion else {
            presentation.setPhase(expanded ? .expanded : .compact)
            surfacePanel.setFrame(destination, display: true)
            surfacePanel.orderFrontRegardless()
            return
        }

        if expanded {
            presentation.setPhase(.expanding)
            transitionTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.transitionGeneration == generation else {
                    return
                }

                self.animatePanel(
                    to: destination,
                    duration: 0.35,
                    timingFunction: CAMediaTimingFunction(
                        controlPoints: 0.16,
                        1.0,
                        0.30,
                        1.0
                    )
                )

                try? await Task.sleep(nanoseconds: 70_000_000)
                guard
                    !Task.isCancelled,
                    self.transitionGeneration == generation
                else {
                    return
                }
                self.presentation.setPhase(.expanded)
            }
        } else {
            presentation.setPhase(.collapsing)
            transitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard
                    let self,
                    !Task.isCancelled,
                    self.transitionGeneration == generation
                else {
                    return
                }

                self.presentation.setPhase(.shrinking)
                self.animatePanel(
                    to: destination,
                    duration: 0.30,
                    timingFunction: CAMediaTimingFunction(
                        controlPoints: 0.40,
                        0.0,
                        0.20,
                        1.0
                    )
                )

                try? await Task.sleep(nanoseconds: 200_000_000)
                guard
                    !Task.isCancelled,
                    self.transitionGeneration == generation
                else {
                    return
                }
                self.presentation.setPhase(.compact)
            }
        }
    }

    private func animatePanel(
        to frame: NSRect,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timingFunction
            surfacePanel.animator().setFrame(frame, display: true)
        }
    }

    private func refreshAllIfStale() {
        claudeStore.refresh()
        Task { await usageStore.refreshIfStale() }
    }

    private func refreshAll() {
        claudeStore.refresh()
        Task { await usageStore.refresh() }
    }

    private func reposition() {
        guard let screen = preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        currentGeometry = geometry
        presentation.updateLayout(
            notchGapWidth: geometry.notchGapWidth,
            expandedTopReserve: geometry.topBarDepth
        )

        surfacePanel.setFrame(
            isExpanded
                ? geometry.expandedSurfaceFrame
                : geometry.compactSurfaceFrame,
            display: true
        )
        surfacePanel.orderFrontRegardless()
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { NotchGeometry(screen: $0).hasNotch }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func installEventMonitors() {
        if localEventMonitor == nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }

                if
                    event.type == .keyDown,
                    event.keyCode == 53,
                    self.isExpanded
                {
                    self.collapse()
                    return nil
                }

                if
                    event.type == .keyDown,
                    event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                {
                    if event.charactersIgnoringModifiers == "r" {
                        self.refreshAll()
                        return nil
                    }
                    if event.charactersIgnoringModifiers == "q" {
                        NSApplication.shared.terminate(nil)
                        return nil
                    }
                }

                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    self.collapseIfClickIsOutside()
                }
                return event
            }
        }

        if globalEventMonitor == nil {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.collapseIfClickIsOutside()
                }
            }
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func collapseIfClickIsOutside() {
        guard isExpanded else { return }
        guard !surfacePanel.frame.contains(NSEvent.mouseLocation) else { return }
        collapse()
    }

    private func observeScreenChanges() {
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.collapse()
                    self?.reposition()
                }
            }
        )

        notificationTokens.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reposition() }
            }
        )

        notificationTokens.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.collapse()
                    self?.reposition()
                }
            }
        )
    }
}
