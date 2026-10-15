import AppKit
import Combine
import SwiftUI

enum CompactProvider: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: Self { self }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    var shortTitle: String {
        switch self {
        case .codex: "CODEX"
        case .claude: "CLAUDE"
        }
    }

    func remainingPercentage(
        codex: Int?,
        claude: Int?
    ) -> Int? {
        switch self {
        case .codex: codex
        case .claude: claude
        }
    }
}

enum NotchPresentationPhase: Equatable {
    case idle
    case revealingCompact
    case compact
    case expanding
    case expanded
    case collapsing
    case shrinking
    case hidingCompact

    var shellIsExpanded: Bool {
        switch self {
        case .expanding, .expanded, .collapsing:
            true
        case .idle, .revealingCompact, .compact, .shrinking, .hidingCompact:
            false
        }
    }

    var showsCompactContent: Bool {
        self == .compact
    }

    var showsExpandedContent: Bool {
        self == .expanded
    }

    var showsIdleOpener: Bool {
        switch self {
        case .idle, .revealingCompact, .hidingCompact:
            true
        default:
            false
        }
    }

    var usesExpandedFrame: Bool {
        switch self {
        case .expanding, .expanded, .collapsing:
            true
        default:
            false
        }
    }

    var usesIdleFrame: Bool {
        self == .idle || self == .hidingCompact
    }
}

struct NotchPresentationLayout: Equatable {
    let compact: NotchCompactLayout
    let expandedTopReserve: CGFloat

    var notchGapWidth: CGFloat { compact.centerWidth }

    static let fallback = NotchPresentationLayout(
        compact: NotchCompactLayout(
            hasHardwareNotch: false,
            surfaceHeight: 21,
            bottomClearance: 4,
            centerWidth: 112,
            wingWidth: 44,
            metricScale: 21 / NotchGeometry.standardCompactHeight,
            backingScaleFactor: 2
        ),
        expandedTopReserve: NotchGeometry.fallbackTopBarDepth
    )
}

@MainActor
final class NotchPresentationModel: ObservableObject {
    static let compactProviderKey = "compactProvider"
    static let compactContentLockedKey = "compactContentLocked"
    static let automaticRefreshEnabledKey = "automaticRefreshEnabled"

    @Published private(set) var phase: NotchPresentationPhase
    @Published private(set) var layout: NotchPresentationLayout
    @Published var compactProvider: CompactProvider {
        didSet {
            defaults.set(
                compactProvider.rawValue,
                forKey: Self.compactProviderKey
            )
        }
    }
    @Published var isCompactContentLocked: Bool {
        didSet {
            defaults.set(
                isCompactContentLocked,
                forKey: Self.compactContentLockedKey
            )
        }
    }
    @Published var isAutomaticRefreshEnabled: Bool {
        didSet {
            defaults.set(
                isAutomaticRefreshEnabled,
                forKey: Self.automaticRefreshEnabledKey
            )
        }
    }

    private let defaults: UserDefaults

    var notchGapWidth: CGFloat { layout.notchGapWidth }
    var expandedTopReserve: CGFloat { layout.expandedTopReserve }

    init(
        defaults: UserDefaults = .standard,
        layout: NotchPresentationLayout = .fallback
    ) {
        self.defaults = defaults
        self.layout = layout
        let compactContentLocked = defaults.bool(
            forKey: Self.compactContentLockedKey
        )
        phase = compactContentLocked ? .compact : .idle
        isCompactContentLocked = compactContentLocked
        isAutomaticRefreshEnabled = defaults.bool(
            forKey: Self.automaticRefreshEnabledKey
        )
        compactProvider = CompactProvider(
            rawValue: defaults.string(forKey: Self.compactProviderKey) ?? ""
        ) ?? .codex
    }

    func setPhase(_ phase: NotchPresentationPhase) {
        self.phase = phase
    }

    func shouldHideCompact(pointerIsInside: Bool) -> Bool {
        !isCompactContentLocked && !pointerIsInside
    }

    func updateLayout(_ layout: NotchPresentationLayout) {
        if layout != self.layout {
            self.layout = layout
        }
    }
}

final class NotchFooterHelpModel: ObservableObject {
    @Published private(set) var text: String?

    func setHover(_ text: String, isHovering: Bool) {
        if isHovering {
            self.text = text
        } else if self.text == text {
            self.text = nil
        }
    }

    func clear() {
        text = nil
    }
}

struct NotchCompactMetrics: Equatable {
    let topEarRadius: CGFloat
    let bottomRadius: CGFloat
    let contentEdgeInset: CGFloat
    let logoSize: CGFloat
    let percentFontSize: CGFloat
    let percentMinimumScale: CGFloat
    let contentRevealOffset: CGFloat
}

enum NotchLayout {
    static let menuBarPercentFontSize = NSFont.menuBarFont(ofSize: 0).pointSize
    static let standardCompactMetrics = NotchCompactMetrics(
        topEarRadius: 12,
        bottomRadius: 14,
        contentEdgeInset: 16,
        logoSize: 20,
        percentFontSize: 14,
        percentMinimumScale: 0.8,
        contentRevealOffset: 3
    )
    static let expandedTopEarRadius: CGFloat = 18
    static let expandedBottomRadius: CGFloat = 22
    static let footerHorizontalInset: CGFloat = 36

    static func compactMetrics(
        for layout: NotchPresentationLayout
    ) -> NotchCompactMetrics {
        let compact = layout.compact
        let scale = compact.metricScale
        let backingScale = max(1, compact.backingScaleFactor)
        let scaledTopEarRadius = clamped(
            standardCompactMetrics.topEarRadius * scale,
            minimum: 5,
            maximum: 14
        )
        let topEarRadius = compact.hasHardwareNotch
            ? scaledTopEarRadius
            : min(scaledTopEarRadius, compact.surfaceHeight / 3)
        let scaledBottomRadius = clamped(
            standardCompactMetrics.bottomRadius * scale,
            minimum: 8,
            maximum: 16
        )
        let bottomRadius = compact.hasHardwareNotch
            ? scaledBottomRadius
            : min(
                scaledBottomRadius,
                compact.surfaceHeight - topEarRadius
            )

        return NotchCompactMetrics(
            topEarRadius: pixelAligned(
                topEarRadius,
                backingScale: backingScale
            ),
            bottomRadius: pixelAligned(
                bottomRadius,
                backingScale: backingScale
            ),
            contentEdgeInset: pixelAligned(
                clamped(
                    standardCompactMetrics.contentEdgeInset * scale,
                    minimum: 10,
                    maximum: 18
                ),
                backingScale: backingScale
            ),
            logoSize: pixelAligned(
                clamped(
                    standardCompactMetrics.logoSize * scale,
                    minimum: 16,
                    maximum: 22
                ),
                backingScale: backingScale
            ),
            percentFontSize: pixelAligned(
                clamped(
                    standardCompactMetrics.percentFontSize * scale,
                    minimum: menuBarPercentFontSize,
                    maximum: 15
                ),
                backingScale: backingScale
            ),
            percentMinimumScale: standardCompactMetrics.percentMinimumScale,
            contentRevealOffset: pixelAligned(
                clamped(
                    standardCompactMetrics.contentRevealOffset * scale,
                    minimum: 2,
                    maximum: 3.5
                ),
                backingScale: backingScale
            )
        )
    }

    /// Match the native menu-bar text baseline by lowering the compact usage
    /// label by exactly one physical display pixel at any backing scale.
    static func compactPercentVerticalOffset(
        for layout: NotchPresentationLayout
    ) -> CGFloat {
        1 / max(1, layout.compact.backingScaleFactor)
    }

    private static func pixelAligned(
        _ value: CGFloat,
        backingScale: CGFloat
    ) -> CGFloat {
        (value * backingScale).rounded() / backingScale
    }

    private static func clamped(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        min(maximum, max(minimum, value))
    }
}

struct NotchSilhouette: Shape {
    var topEarRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topEarRadius, bottomRadius) }
        set {
            topEarRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ear = min(topEarRadius, rect.width / 4, rect.height / 3)
        let bottom = min(
            bottomRadius,
            (rect.width - 2 * ear) / 2,
            rect.height - ear
        )

        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + ear, y: rect.minY + ear),
                control: CGPoint(x: rect.minX + ear, y: rect.minY)
            )
            path.addLine(
                to: CGPoint(x: rect.minX + ear, y: rect.maxY - bottom)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + ear + bottom, y: rect.maxY),
                control: CGPoint(x: rect.minX + ear, y: rect.maxY)
            )
            path.addLine(
                to: CGPoint(x: rect.maxX - ear - bottom, y: rect.maxY)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - ear, y: rect.maxY - bottom),
                control: CGPoint(x: rect.maxX - ear, y: rect.maxY)
            )
            path.addLine(
                to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear)
            )
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control: CGPoint(x: rect.maxX - ear, y: rect.minY)
            )
            path.closeSubpath()
        }
    }
}

private struct NotchPalette {
    let surface = Color.black
    let track = Color(red: 43 / 255, green: 47 / 255, blue: 55 / 255)
    let text = Color(red: 245 / 255, green: 247 / 255, blue: 250 / 255)
    let muted = Color(red: 142 / 255, green: 148 / 255, blue: 158 / 255)
    let seam = Color.white.opacity(0.09)
    let control = Color.white.opacity(0.07)
    let selectedControl = Color.white.opacity(0.14)
    let unavailable = Color.white.opacity(0.18)
    let codex = Color(red: 108 / 255, green: 141 / 255, blue: 255 / 255)
    let claude = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    let warning = Color(red: 255 / 255, green: 180 / 255, blue: 84 / 255)
}

private struct NotchPaletteKey: EnvironmentKey {
    static let defaultValue = NotchPalette()
}

private extension EnvironmentValues {
    var notchPalette: NotchPalette {
        get { self[NotchPaletteKey.self] }
        set { self[NotchPaletteKey.self] = newValue }
    }
}

struct NotchSurfaceView: View {
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var claudeStore: ClaudeUsageStore
    @ObservedObject var presentation: NotchPresentationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onRefresh: () -> Void
    let onOpenCodex: () -> Void
    let onExpand: () -> Void
    let onCompactHover: (Bool) -> Void
    let onClose: () -> Void
    let onQuit: () -> Void

    private var compactMetrics: NotchCompactMetrics {
        NotchLayout.compactMetrics(for: presentation.layout)
    }

    private var silhouette: NotchSilhouette {
        NotchSilhouette(
            topEarRadius: presentation.phase.shellIsExpanded
                ? NotchLayout.expandedTopEarRadius
                : compactMetrics.topEarRadius,
            bottomRadius: presentation.phase.shellIsExpanded
                ? NotchLayout.expandedBottomRadius
                : compactMetrics.bottomRadius
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                silhouette.fill(Color.black)

                NotchDashboardView(
                    usageStore: usageStore,
                    claudeStore: claudeStore,
                    presentation: presentation,
                    onRefresh: onRefresh,
                    onOpenCodex: onOpenCodex,
                    onClose: onClose,
                    onQuit: onQuit
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .opacity(presentation.phase.showsExpandedContent ? 1 : 0)
                .offset(
                    y: reduceMotion
                        || presentation.phase.showsExpandedContent
                        ? 0
                        : 4
                )
                .allowsHitTesting(presentation.phase.showsExpandedContent)
                .accessibilityHidden(!presentation.phase.showsExpandedContent)
                .animation(
                    reduceMotion
                        ? nil
                        : presentation.phase.showsExpandedContent
                            ? .easeOut(
                                duration: NotchMotion.expandedContentDuration
                            )
                            : .easeIn(duration: 0.10),
                    value: presentation.phase.showsExpandedContent
                )

                NotchCompactView(
                    usageStore: usageStore,
                    claudeStore: claudeStore,
                    presentation: presentation,
                    onExpand: onExpand,
                    onHoverChange: onCompactHover
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .opacity(presentation.phase.showsCompactContent ? 1 : 0)
                .allowsHitTesting(presentation.phase.showsCompactContent)
                .accessibilityHidden(!presentation.phase.showsCompactContent)
                .animation(
                    reduceMotion
                        ? nil
                        : presentation.phase.showsCompactContent
                            ? .easeOut(duration: NotchMotion.compactContentDuration)
                            : .easeIn(duration: NotchMotion.compactContentHideDuration),
                    value: presentation.phase.showsCompactContent
                )

                if presentation.phase.showsIdleOpener {
                    Button(action: onExpand) {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open usage dashboard")
                    .accessibilityHint("Shows Codex and Claude usage")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(silhouette)
            .animation(
                reduceMotion
                    ? nil
                    : .timingCurve(
                        0.20,
                        0.80,
                        0.20,
                        1.00,
                        duration: NotchMotion.expandDuration
                    ),
                value: presentation.phase.shellIsExpanded
            )
        }
        .environment(\.notchPalette, NotchPalette())
        .preferredColorScheme(.dark)
    }
}

private struct NotchCompactView: View {
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var claudeStore: ClaudeUsageStore
    @ObservedObject var presentation: NotchPresentationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onExpand: () -> Void
    let onHoverChange: (Bool) -> Void

    @State private var isHovering = false

    private var compactMetrics: NotchCompactMetrics {
        NotchLayout.compactMetrics(for: presentation.layout)
    }

    private var remainingPercent: Int? {
        presentation.compactProvider.remainingPercentage(
            codex: usageStore.snapshot?.weekly?.remainingPercent,
            claude: claudeStore.snapshot?.remainingPercent
        )
    }

    private var accessibilityValue: String {
        if let remainingPercent {
            return "\(remainingPercent) percent remaining"
        }
        if presentation.compactProvider == .codex, usageStore.isRefreshing {
            return "Loading"
        }
        return "Unavailable"
    }

    var body: some View {
        GeometryReader { geometry in
            let wingWidth = max(
                0,
                (geometry.size.width - presentation.notchGapWidth) / 2
            )

            Button(action: onExpand) {
                HStack(spacing: 0) {
                    ZStack(alignment: .leading) {
                        providerLogo
                            .offset(
                                x: reduceMotion
                                    || presentation.phase.showsCompactContent
                                    ? 0
                                    : compactMetrics.contentRevealOffset
                            )
                            .padding(.leading, compactMetrics.contentEdgeInset)
                    }
                    .frame(width: wingWidth, height: geometry.size.height)

                    Color.clear
                        .frame(
                            width: presentation.notchGapWidth,
                            height: geometry.size.height
                        )

                    ZStack(alignment: .trailing) {
                        Text(remainingPercent.map { "\($0)%" } ?? "—")
                            .font(.system(
                                size: compactMetrics.percentFontSize,
                                weight: .medium,
                                design: .default
                            ))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(
                                compactMetrics.percentMinimumScale
                            )
                            .foregroundStyle(.white.opacity(isHovering ? 1 : 0.92))
                            .offset(
                                x: reduceMotion
                                    || presentation.phase.showsCompactContent
                                    ? 0
                                    : -compactMetrics.contentRevealOffset,
                                y: NotchLayout.compactPercentVerticalOffset(
                                    for: presentation.layout
                                )
                            )
                            .padding(.trailing, compactMetrics.contentEdgeInset)
                    }
                    .frame(width: wingWidth, height: geometry.size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(
                    NotchSilhouette(
                        topEarRadius: compactMetrics.topEarRadius,
                        bottomRadius: compactMetrics.bottomRadius
                    )
                )
            }
            .buttonStyle(.plain)
            .onHover {
                isHovering = $0
                onHoverChange($0)
            }
            .accessibilityLabel("Open \(presentation.compactProvider.title) usage")
            .accessibilityValue(accessibilityValue)
            .help("Open Codex and Claude usage")
        }
    }

    @ViewBuilder
    private var providerLogo: some View {
        switch presentation.compactProvider {
        case .codex:
            CodexGlyphView(size: compactMetrics.logoSize)
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.92))
        case .claude:
            ClaudeLogoView(size: compactMetrics.logoSize)
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.92))
        }
    }
}

struct NotchDashboardView: View {
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var claudeStore: ClaudeUsageStore
    @ObservedObject var presentation: NotchPresentationModel

    let onRefresh: () -> Void
    let onOpenCodex: () -> Void
    let onClose: () -> Void
    let onQuit: () -> Void

    @Environment(\.notchPalette) private var palette
    @StateObject private var footerHelp = NotchFooterHelpModel()

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: presentation.expandedTopReserve)

            dashboardContent
                .frame(
                    width: NotchGeometry.dashboardSize.width,
                    height: NotchGeometry.dashboardSize.height
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand(perform: onClose)
        .onChange(of: presentation.phase) { phase in
            if !phase.showsExpandedContent {
                footerHelp.clear()
            }
        }
    }

    private var dashboardContent: some View {
        dashboardLayout
            .overlay(alignment: .bottom) {
                footerHelpBlurb
            }
            .animation(.easeOut(duration: 0.12), value: footerHelp.text)
    }

    private var dashboardLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CodexCapacityPane(store: usageStore)

                Rectangle()
                    .fill(palette.seam)
                    .frame(width: 1)
                    .padding(.vertical, 4)

                ClaudeCapacityPane(store: claudeStore)
            }
            .padding(.horizontal, 18)
            .padding(.top, 11)
            .padding(.bottom, 10)

            Rectangle()
                .fill(palette.seam)
                .frame(height: 1)

            HStack(spacing: 8) {
                CompactProviderPicker(
                    presentation: presentation,
                    helpModel: footerHelp
                )

                CompactVisibilityButton(
                    presentation: presentation,
                    helpModel: footerHelp
                )

                AutomaticRefreshButton(
                    presentation: presentation,
                    helpModel: footerHelp
                )

                Spacer()

                if claudeStore.supportsClaudeConnection {
                    NotchActionButton(
                        title: "Claude accounts",
                        helpText: "Manage Claude accounts. The notch follows the active Claude Code subscription.",
                        systemImage: "person.2.crop.square.stack",
                        helpModel: footerHelp,
                        action: claudeStore.showClaudeConnection
                    )
                }

                NotchActionButton(
                    title: "Refresh all",
                    helpText: "Refresh Codex and Claude usage now.",
                    systemImage: "arrow.clockwise",
                    helpModel: footerHelp,
                    action: onRefresh
                )
                .disabled(usageStore.isRefreshing || claudeStore.isRefreshing)

                NotchActionButton(
                    title: "Open Codex",
                    helpText: "Open the Codex app.",
                    systemImage: "arrow.up.forward.app",
                    helpModel: footerHelp,
                    action: onOpenCodex
                )

                NotchActionButton(
                    title: "Close",
                    helpText: "Collapse the usage dashboard.",
                    systemImage: "chevron.up",
                    helpModel: footerHelp,
                    action: onClose
                )

                Rectangle()
                    .fill(palette.seam)
                    .frame(width: 1, height: 16)

                NotchActionButton(
                    title: "Quit",
                    helpText: "Quit Agent Usage.",
                    systemImage: "power",
                    helpModel: footerHelp,
                    action: onQuit
                )
            }
            .padding(.horizontal, NotchLayout.footerHorizontalInset)
            .frame(height: 38)
        }
    }

    @ViewBuilder
    private var footerHelpBlurb: some View {
        if let text = footerHelp.text {
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    palette.track,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(palette.seam, lineWidth: 1)
                }
                .padding(.bottom, 42)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .offset(y: 2)))
        }
    }
}

private struct AutomaticRefreshButton: View {
    @ObservedObject var presentation: NotchPresentationModel
    let helpModel: NotchFooterHelpModel
    @Environment(\.notchPalette) private var palette

    var body: some View {
        Button {
            presentation.isAutomaticRefreshEnabled.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                Text("5m")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.text)
            .frame(width: 39, height: 23)
            .background(
                presentation.isAutomaticRefreshEnabled
                    ? palette.selectedControl
                    : palette.control,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help("Refresh usage automatically every 5 minutes")
        .notchFooterHelp(
            "Refresh usage automatically every 5 minutes.",
            model: helpModel
        )
        .accessibilityLabel("Refresh usage automatically every 5 minutes")
        .accessibilityValue(
            presentation.isAutomaticRefreshEnabled ? "On" : "Off"
        )
        .accessibilityAddTraits(
            presentation.isAutomaticRefreshEnabled ? .isSelected : []
        )
    }
}

private struct CompactVisibilityButton: View {
    @ObservedObject var presentation: NotchPresentationModel
    let helpModel: NotchFooterHelpModel
    @Environment(\.notchPalette) private var palette

    var body: some View {
        Button {
            presentation.isCompactContentLocked.toggle()
        } label: {
            Image(
                systemName: presentation.isCompactContentLocked
                    ? "pin.fill"
                    : "pin"
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.text)
            .frame(width: 25, height: 23)
            .background(
                presentation.isCompactContentLocked
                    ? palette.selectedControl
                    : palette.control,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(
            "Keep compact counters visible; may overlap items on crowded menu bars"
        )
        .notchFooterHelp(
            "Keep compact counters visible after the pointer leaves.",
            model: helpModel
        )
        .accessibilityLabel("Keep compact counters visible")
        .accessibilityHint(
            "May overlap items on crowded menu bars"
        )
        .accessibilityValue(
            presentation.isCompactContentLocked ? "On" : "Off"
        )
        .accessibilityAddTraits(
            presentation.isCompactContentLocked ? .isSelected : []
        )
    }
}

private struct CompactProviderPicker: View {
    @ObservedObject var presentation: NotchPresentationModel
    let helpModel: NotchFooterHelpModel

    var body: some View {
        HStack(spacing: 3) {
            ForEach(CompactProvider.allCases) { provider in
                CompactProviderButton(
                    provider: provider,
                    isSelected: presentation.compactProvider == provider,
                    helpModel: helpModel
                ) {
                    presentation.compactProvider = provider
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compact notch provider")
    }
}

private struct CompactProviderButton: View {
    @Environment(\.notchPalette) private var palette

    let provider: CompactProvider
    let isSelected: Bool
    let helpModel: NotchFooterHelpModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                providerLogo
                Text(provider.shortTitle)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(isSelected ? palette.text : palette.muted)
            .padding(.horizontal, 7)
            .frame(height: 23)
            .background(
                isSelected ? palette.selectedControl : palette.control,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help("Show \(provider.title) when collapsed")
        .notchFooterHelp(
            "Show \(provider.title) usage when the notch is collapsed.",
            model: helpModel
        )
        .accessibilityLabel("Show \(provider.title) in compact notch")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var providerLogo: some View {
        switch provider {
        case .codex:
            CodexGlyphView(size: 11)
        case .claude:
            ClaudeLogoView(size: 11)
        }
    }
}

private struct CodexCapacityPane: View {
    @ObservedObject var store: UsageStore
    @Environment(\.notchPalette) private var palette

    private var window: CodexUsageWindow? {
        store.snapshot?.weekly
    }

    var body: some View {
        CapacityPane(
            name: "CODEX",
            subtitle: "Weekly allowance",
            accent: palette.codex,
            remainingPercent: window?.remainingPercent,
            primaryMeta: resetText,
            secondaryMeta: updatedText,
            logo: AnyView(CodexGlyphView(size: 19)),
            isLoading: store.isRefreshing,
            errorMessage: store.errorMessage
        )
    }

    private var resetText: String {
        guard let resetsAt = window?.resetsAt else {
            return window == nil ? "Waiting for Codex" : "Reset unavailable"
        }
        return "Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var updatedText: String? {
        guard let fetchedAt = store.snapshot?.fetchedAt else { return nil }
        return "Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))"
    }
}

private struct ClaudeCapacityPane: View {
    @ObservedObject var store: ClaudeUsageStore
    @Environment(\.notchPalette) private var palette

    var body: some View {
        CapacityPane(
            name: "CLAUDE CODE",
            subtitle: store.activeAccountLabel ?? "5-hour allowance",
            accent: palette.claude,
            remainingPercent: store.snapshot?.remainingPercent,
            primaryMeta: primaryMeta,
            secondaryMeta: updatedText,
            logo: AnyView(ClaudeLogoView(size: 19)),
            isLoading: store.isRefreshing,
            errorMessage: store.errorMessage,
            connectionAction: connectionAction
        )
    }

    private var connectionAction: (() -> Void)? {
        guard store.supportsClaudeConnection else { return nil }
        return { store.showClaudeConnection() }
    }

    private var primaryMeta: String {
        guard let snapshot = store.snapshot else {
            return store.isRefreshing ? "Fetching Claude usage…" : "Refresh to load Claude usage"
        }

        if snapshot.isAwaitingFirstMessage { return "Starts with your first message" }
        guard let resetsAt = snapshot.resetsAt else {
            return "Reset unavailable"
        }
        return "Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var updatedText: String? {
        guard let updatedAt = store.snapshot?.updatedAt else { return nil }
        return "Updated \(updatedAt.formatted(date: .omitted, time: .shortened))"
    }
}

private struct CapacityPane: View {
    @Environment(\.notchPalette) private var palette

    let name: String
    let subtitle: String
    let accent: Color
    let remainingPercent: Int?
    let primaryMeta: String
    let secondaryMeta: String?
    let logo: AnyView
    let isLoading: Bool
    let errorMessage: String?
    var connectionAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                logo
                    .foregroundStyle(palette.text)
                    .frame(width: 21, height: 21)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(palette.text)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                }

                if remainingPercent == nil, !isLoading, let connectionAction {
                    Button("Accounts", action: connectionAction)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Manage Claude accounts")
                } else {
                    percentage
                }
            }

            CapacityRunway(
                remainingPercent: remainingPercent,
                accent: accent
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(errorMessage ?? primaryMeta)
                    .foregroundStyle(errorMessage == nil ? palette.text : palette.warning)
                    .lineLimit(errorMessage == nil ? 1 : 2)
                if errorMessage == nil, let secondaryMeta {
                    Text(secondaryMeta)
                        .foregroundStyle(palette.muted)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .frame(height: 27, alignment: .top)
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var percentage: some View {
        if let remainingPercent {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(remainingPercent)")
                    .font(.system(size: 27, weight: .semibold, design: .monospaced))
                Text("%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.muted)
            }
            .foregroundStyle(palette.text)
            .accessibilityLabel("\(remainingPercent) percent remaining")
        } else {
            Text("—")
                .font(.system(size: 27, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.muted)
                .accessibilityLabel("Not available")
        }
    }
}

private struct CapacityRunway: View {
    @Environment(\.notchPalette) private var palette

    let remainingPercent: Int?
    let accent: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.track)

                if let remainingPercent {
                    Capsule()
                        .fill(accent)
                        .frame(
                            width: remainingPercent == 0
                                ? 0
                                : max(
                                    5,
                                    geometry.size.width * CGFloat(remainingPercent) / 100
                                )
                        )
                } else {
                    Capsule()
                        .stroke(
                            palette.unavailable,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                }
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

private struct NotchActionButton: View {
    @Environment(\.notchPalette) private var palette

    let title: String
    let helpText: String
    let systemImage: String
    let helpModel: NotchFooterHelpModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.text)
                .frame(width: 25, height: 23)
                .background(
                    palette.control,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .notchFooterHelp(helpText, model: helpModel)
        .accessibilityLabel(title)
    }
}

private struct NotchFooterHelpModifier: ViewModifier {
    let text: String
    let model: NotchFooterHelpModel

    func body(content: Content) -> some View {
        content.onHover { isHovering in
            model.setHover(text, isHovering: isHovering)
        }
    }
}

private extension View {
    func notchFooterHelp(
        _ text: String,
        model: NotchFooterHelpModel
    ) -> some View {
        modifier(NotchFooterHelpModifier(text: text, model: model))
    }
}
