import AppKit
import QuartzCore
import SwiftUI

enum NotchMotion {
    static let idleReturnDelayNanoseconds: UInt64 = 2_000_000_000

    static let compactRevealDuration: TimeInterval = 0.22
    static let compactContentDelayNanoseconds: UInt64 = 50_000_000
    static let compactContentDuration: TimeInterval = 0.14
    static let compactContentHideDuration: TimeInterval = 0.10
    static let compactContentHideDelayNanoseconds: UInt64 = 100_000_000
    static let idleShrinkDuration: TimeInterval = 0.20

    static let expandDuration: TimeInterval = 0.32
    static let expandedContentDelayNanoseconds: UInt64 = 110_000_000
    static let expandedContentDuration: TimeInterval = 0.17
    static let collapseContentDelayNanoseconds: UInt64 = 100_000_000
    static let collapseDuration: TimeInterval = 0.26
}

private final class NotchSurfacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class NotchSurfaceHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    var onIdlePrimaryClick: (() -> Bool)?

    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if onIdlePrimaryClick?() == true {
            return
        }
        super.mouseDown(with: event)
    }
}

/// A transparent, notch-width target that keeps the five-point visual gap
/// clickable without making either menu-bar wing part of the app window.
private final class NotchActivationView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onActivate: (() -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }
        onActivate?()
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
    private var activationPanel: NSPanel!
    private var currentGeometry: NotchGeometry?
    private var isExpanded = false
    private var transitionGeneration = 0
    private var transitionTask: Task<Void, Never>?
    private var compactHideGeneration = 0
    private var compactHideTask: Task<Void, Never>?

    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var localPointerEventMonitor: Any?
    private var globalPointerEventMonitor: Any?
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
        compactHideTask?.cancel()
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
        if let localPointerEventMonitor {
            NSEvent.removeMonitor(localPointerEventMonitor)
        }
        if let globalPointerEventMonitor {
            NSEvent.removeMonitor(globalPointerEventMonitor)
        }
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    func start() {
        reposition()
        surfacePanel.orderFrontRegardless()
        showActivationPanel()
        installPointerEventMonitors()
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
        surfacePanel.acceptsMouseMovedEvents = true
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
                onCompactHover: { [weak self] isHovering in
                    self?.handleCompactHover(isHovering)
                },
                onClose: { [weak self] in self?.collapse() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )
        hostingView.onHoverChange = { [weak self] isHovering in
            self?.handleCompactHover(isHovering)
        }
        hostingView.onIdlePrimaryClick = { [weak self] in
            guard let self else { return false }
            switch self.presentation.phase {
            case .idle, .revealingCompact, .hidingCompact:
                self.expand()
                return true
            default:
                return false
            }
        }
        hostingView.sizingOptions = []
        surfacePanel.contentView = hostingView
        surfacePanel.contentMinSize = .zero
        surfacePanel.minSize = .zero

        configureActivationPanel()
    }

    private func configureActivationPanel() {
        activationPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        activationPanel.backgroundColor = .clear
        activationPanel.isOpaque = false
        activationPanel.hasShadow = false
        activationPanel.hidesOnDeactivate = false
        activationPanel.isReleasedWhenClosed = false
        activationPanel.isMovable = false
        activationPanel.isFloatingPanel = true
        activationPanel.becomesKeyOnlyIfNeeded = true
        activationPanel.canHide = false
        activationPanel.isRestorable = false
        activationPanel.acceptsMouseMovedEvents = true
        activationPanel.level = Self.surfaceLevel
        activationPanel.animationBehavior = .none
        activationPanel.collectionBehavior = surfacePanel.collectionBehavior

        let activationView = NotchActivationView(frame: .zero)
        activationView.onHoverChange = { [weak self] isHovering in
            self?.handleCompactHover(isHovering)
        }
        activationView.onActivate = { [weak self] in
            self?.expand()
        }
        activationPanel.contentView = activationView
        activationPanel.contentMinSize = .zero
        activationPanel.minSize = .zero
    }

    private func showActivationPanel() {
        guard !isExpanded else { return }
        activationPanel.ignoresMouseEvents = false
        activationPanel.orderFrontRegardless()
    }

    private func hideActivationPanel() {
        activationPanel.ignoresMouseEvents = true
        activationPanel.orderOut(nil)
    }

    private func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard
            expanded != isExpanded,
            let geometry = currentGeometry
        else {
            return
        }

        isExpanded = expanded
        cancelCompactHide()
        transitionGeneration += 1
        let generation = transitionGeneration
        transitionTask?.cancel()

        if expanded {
            hideActivationPanel()
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
            if !expanded {
                finishCompactReturn()
            }
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
                    duration: NotchMotion.expandDuration,
                    timingFunction: CAMediaTimingFunction(
                        controlPoints: 0.20,
                        0.80,
                        0.20,
                        1.00
                    )
                )

                try? await Task.sleep(
                    nanoseconds: NotchMotion.expandedContentDelayNanoseconds
                )
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
                try? await Task.sleep(
                    nanoseconds: NotchMotion.collapseContentDelayNanoseconds
                )
                guard
                    let self,
                    !Task.isCancelled,
                    self.transitionGeneration == generation
                else {
                    return
                }

                self.presentation.setPhase(.shrinking)
                await self.animatePanelAndWait(
                    to: destination,
                    duration: NotchMotion.collapseDuration,
                    timingFunction: CAMediaTimingFunction(
                        controlPoints: 0.40,
                        0.0,
                        0.20,
                        1.0
                    )
                )

                guard
                    !Task.isCancelled,
                    self.transitionGeneration == generation
                else {
                    return
                }
                self.presentation.setPhase(.compact)
                self.finishCompactReturn()
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

    private func animatePanelAndWait(
        to frame: NSRect,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction
    ) async {
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = timingFunction
                surfacePanel.animator().setFrame(frame, display: true)
            } completionHandler: {
                continuation.resume()
            }
        }
    }

    private func showCompact(animated: Bool = true) {
        guard
            !isExpanded,
            let geometry = currentGeometry
        else {
            return
        }

        cancelCompactHide()

        switch presentation.phase {
        case .compact, .revealingCompact:
            return
        case .expanding, .expanded, .collapsing, .shrinking:
            return
        case .idle, .hidingCompact:
            break
        }

        refreshAllIfStale()
        transitionGeneration += 1
        let generation = transitionGeneration
        transitionTask?.cancel()
        presentation.setPhase(.revealingCompact)
        surfacePanel.orderFrontRegardless()

        let reduceMotion = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion else {
            surfacePanel.setFrame(geometry.compactSurfaceFrame, display: true)
            presentation.setPhase(.compact)
            return
        }

        animatePanel(
            to: geometry.compactSurfaceFrame,
            duration: NotchMotion.compactRevealDuration,
            timingFunction: CAMediaTimingFunction(
                controlPoints: 0.20,
                0.80,
                0.20,
                1.00
            )
        )

        transitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: NotchMotion.compactContentDelayNanoseconds
            )
            guard
                let self,
                !Task.isCancelled,
                self.transitionGeneration == generation
            else {
                return
            }
            self.presentation.setPhase(.compact)
        }
    }

    private func scheduleCompactHide() {
        guard
            compactHideTask == nil,
            !isExpanded,
            presentation.shouldHideCompact(
                pointerIsInside: pointerIsInsideCompactTarget
            )
        else {
            return
        }

        switch presentation.phase {
        case .compact, .revealingCompact:
            break
        default:
            return
        }

        compactHideGeneration += 1
        let generation = compactHideGeneration
        compactHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: NotchMotion.idleReturnDelayNanoseconds
            )
            guard
                let self,
                !Task.isCancelled,
                self.compactHideGeneration == generation
            else {
                return
            }

            self.compactHideTask = nil
            guard self.presentation.shouldHideCompact(
                pointerIsInside: self.pointerIsInsideCompactTarget
            ) else {
                return
            }
            self.hideCompact()
        }
    }

    private func cancelCompactHide() {
        compactHideGeneration += 1
        compactHideTask?.cancel()
        compactHideTask = nil
    }

    private func hideCompact(animated: Bool = true) {
        guard
            !isExpanded,
            let geometry = currentGeometry,
            presentation.shouldHideCompact(
                pointerIsInside: pointerIsInsideCompactTarget
            )
        else {
            return
        }

        switch presentation.phase {
        case .compact, .revealingCompact:
            break
        default:
            return
        }

        cancelCompactHide()
        transitionGeneration += 1
        let generation = transitionGeneration
        transitionTask?.cancel()
        presentation.setPhase(.hidingCompact)

        let reduceMotion = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion else {
            surfacePanel.setFrame(geometry.idleSurfaceFrame, display: true)
            presentation.setPhase(.idle)
            return
        }

        transitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: NotchMotion.compactContentHideDelayNanoseconds
            )
            guard
                let self,
                !Task.isCancelled,
                self.transitionGeneration == generation
            else {
                return
            }

            await self.animatePanelAndWait(
                to: geometry.idleSurfaceFrame,
                duration: NotchMotion.idleShrinkDuration,
                timingFunction: CAMediaTimingFunction(
                    controlPoints: 0.40,
                    0.0,
                    0.20,
                    1.0
                )
            )

            guard
                !Task.isCancelled,
                self.transitionGeneration == generation
            else {
                return
            }
            self.presentation.setPhase(.idle)
        }
    }

    private func finishCompactReturn() {
        showActivationPanel()
        if presentation.shouldHideCompact(
            pointerIsInside: pointerIsInsideCompactTarget
        ) {
            scheduleCompactHide()
        } else {
            cancelCompactHide()
        }
    }

    private var pointerIsInsideCompactTarget: Bool {
        guard let geometry = currentGeometry else { return false }
        let location = NSEvent.mouseLocation
        return surfacePanel.frame.contains(location)
            || geometry.idleActivationFrame.contains(location)
    }

    private func refreshAllIfStale() {
        claudeStore.refresh()
        Task { await usageStore.refreshIfStale() }
    }

    private func refreshAll() {
        claudeStore.refresh()
        Task { await usageStore.refresh() }
    }

    private func installPointerEventMonitors() {
        if localPointerEventMonitor == nil {
            localPointerEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .mouseMoved
            ) { [weak self] event in
                self?.handlePointerMovement()
                return event
            }
        }

        if globalPointerEventMonitor == nil {
            globalPointerEventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: .mouseMoved
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handlePointerMovement()
                }
            }
        }
    }

    private func handlePointerMovement() {
        guard !isExpanded else { return }

        if pointerIsInsideCompactTarget {
            handleCompactHover(true)
        } else {
            handleCompactHover(false)
        }
    }

    private func handleCompactHover(_ isHovering: Bool) {
        guard !isExpanded else { return }

        if isHovering {
            cancelCompactHide()
            showCompact()
            return
        }

        scheduleCompactHide()
    }

    private func reposition() {
        guard let screen = preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        currentGeometry = geometry
        presentation.updateLayout(
            notchGapWidth: geometry.notchGapWidth,
            expandedTopReserve: geometry.topBarDepth
        )

        let frame: NSRect
        if presentation.phase.usesExpandedFrame {
            frame = geometry.expandedSurfaceFrame
        } else if presentation.phase.usesIdleFrame {
            frame = geometry.idleSurfaceFrame
        } else {
            frame = geometry.compactSurfaceFrame
        }

        surfacePanel.setFrame(frame, display: true)
        activationPanel.setFrame(geometry.idleActivationFrame, display: false)
        surfacePanel.orderFrontRegardless()
    }

    private func resetCollapsedPresentation() {
        transitionGeneration += 1
        transitionTask?.cancel()
        transitionTask = nil
        cancelCompactHide()
        removeEventMonitors()
        isExpanded = false
        surfacePanel.resignKey()
        presentation.setPhase(
            presentation.isCompactContentLocked ? .compact : .idle
        )
        reposition()
        showActivationPanel()
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
                    self?.resetCollapsedPresentation()
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
                    self?.resetCollapsedPresentation()
                }
            }
        )
    }
}
