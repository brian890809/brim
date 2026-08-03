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
    case compact
    case expanding
    case expanded
    case collapsing
    case shrinking

    var shellIsExpanded: Bool {
        switch self {
        case .expanding, .expanded, .collapsing:
            true
        case .compact, .shrinking:
            false
        }
    }

    var showsCompactContent: Bool {
        self == .compact
    }

    var showsExpandedContent: Bool {
        self == .expanded
    }
}

@MainActor
final class NotchPresentationModel: ObservableObject {
    static let compactProviderKey = "compactProvider"

    @Published private(set) var phase: NotchPresentationPhase = .compact
    @Published private(set) var notchGapWidth: CGFloat
    @Published private(set) var expandedTopReserve: CGFloat
    @Published var compactProvider: CompactProvider {
        didSet {
            defaults.set(
                compactProvider.rawValue,
                forKey: Self.compactProviderKey
            )
        }
    }

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        notchGapWidth: CGFloat = NotchGeometry.fallbackNotchGapWidth,
        expandedTopReserve: CGFloat = NotchGeometry.fallbackTopBarDepth
    ) {
        self.defaults = defaults
        self.notchGapWidth = notchGapWidth
        self.expandedTopReserve = expandedTopReserve
        compactProvider = CompactProvider(
            rawValue: defaults.string(forKey: Self.compactProviderKey) ?? ""
        ) ?? .codex
    }

    func setPhase(_ phase: NotchPresentationPhase) {
        self.phase = phase
    }

    func updateLayout(notchGapWidth: CGFloat, expandedTopReserve: CGFloat) {
        if notchGapWidth != self.notchGapWidth {
            self.notchGapWidth = notchGapWidth
        }
        if expandedTopReserve != self.expandedTopReserve {
            self.expandedTopReserve = expandedTopReserve
        }
    }
}

enum NotchLayout {
    static let compactTopEarRadius: CGFloat = 12
    static let compactBottomRadius: CGFloat = 14
    static let expandedTopEarRadius: CGFloat = 18
    static let expandedBottomRadius: CGFloat = 22
    static let compactContentEdgeInset: CGFloat = 24
    static let footerHorizontalInset: CGFloat = 36
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
    let onClose: () -> Void
    let onQuit: () -> Void

    private var silhouette: NotchSilhouette {
        NotchSilhouette(
            topEarRadius: presentation.phase.shellIsExpanded
                ? NotchLayout.expandedTopEarRadius
                : NotchLayout.compactTopEarRadius,
            bottomRadius: presentation.phase.shellIsExpanded
                ? NotchLayout.expandedBottomRadius
                : NotchLayout.compactBottomRadius
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
                .offset(y: presentation.phase.showsExpandedContent ? 0 : 6)
                .allowsHitTesting(presentation.phase.showsExpandedContent)
                .accessibilityHidden(!presentation.phase.showsExpandedContent)
                .animation(
                    reduceMotion
                        ? nil
                        : presentation.phase.showsExpandedContent
                            ? .easeOut(duration: 0.19)
                            : .easeIn(duration: 0.10),
                    value: presentation.phase.showsExpandedContent
                )

                NotchCompactView(
                    usageStore: usageStore,
                    claudeStore: claudeStore,
                    presentation: presentation,
                    onExpand: onExpand
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .opacity(presentation.phase.showsCompactContent ? 1 : 0)
                .allowsHitTesting(presentation.phase.showsCompactContent)
                .accessibilityHidden(!presentation.phase.showsCompactContent)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.10),
                    value: presentation.phase.showsCompactContent
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(silhouette)
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.35, dampingFraction: 0.82),
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

    let onExpand: () -> Void

    @State private var isHovering = false

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
                            .padding(.leading, NotchLayout.compactContentEdgeInset)
                    }
                    .frame(width: wingWidth, height: geometry.size.height)

                    Color.clear
                        .frame(
                            width: presentation.notchGapWidth,
                            height: geometry.size.height
                        )

                    ZStack(alignment: .trailing) {
                        Text(remainingPercent.map { "\($0)%" } ?? "—")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(isHovering ? 1 : 0.92))
                            .padding(.trailing, NotchLayout.compactContentEdgeInset)
                    }
                    .frame(width: wingWidth, height: geometry.size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(
                    NotchSilhouette(
                        topEarRadius: NotchLayout.compactTopEarRadius,
                        bottomRadius: NotchLayout.compactBottomRadius
                    )
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel("Open \(presentation.compactProvider.title) usage")
            .accessibilityValue(accessibilityValue)
            .help("Open Codex and Claude usage")
        }
    }

    @ViewBuilder
    private var providerLogo: some View {
        switch presentation.compactProvider {
        case .codex:
            CodexGlyphView(size: 20)
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.92))
        case .claude:
            ClaudeLogoView(size: 20)
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
    }

    private var dashboardContent: some View {
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
                CompactProviderPicker(presentation: presentation)

                Spacer()

                NotchActionButton(
                    title: "Refresh all",
                    systemImage: "arrow.clockwise",
                    action: onRefresh
                )
                .disabled(usageStore.isRefreshing)

                NotchActionButton(
                    title: "Open Codex",
                    systemImage: "arrow.up.forward.app",
                    action: onOpenCodex
                )

                NotchActionButton(
                    title: "Close",
                    systemImage: "chevron.up",
                    action: onClose
                )

                Rectangle()
                    .fill(palette.seam)
                    .frame(width: 1, height: 16)

                NotchActionButton(
                    title: "Quit",
                    systemImage: "power",
                    action: onQuit
                )
            }
            .padding(.horizontal, NotchLayout.footerHorizontalInset)
            .frame(height: 38)
        }
    }
}

private struct CompactProviderPicker: View {
    @ObservedObject var presentation: NotchPresentationModel

    var body: some View {
        HStack(spacing: 3) {
            ForEach(CompactProvider.allCases) { provider in
                CompactProviderButton(
                    provider: provider,
                    isSelected: presentation.compactProvider == provider
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
            subtitle: "5-hour allowance",
            accent: palette.claude,
            remainingPercent: store.snapshot?.remainingPercent,
            primaryMeta: primaryMeta,
            secondaryMeta: updatedText,
            logo: AnyView(ClaudeLogoView(size: 19)),
            isLoading: false,
            errorMessage: store.errorMessage
        )
    }

    private var primaryMeta: String {
        guard let snapshot = store.snapshot else {
            return "Waiting for Claude usage"
        }

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

                percentage
            }

            CapacityRunway(
                remainingPercent: remainingPercent,
                accent: accent
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(errorMessage ?? primaryMeta)
                    .foregroundStyle(errorMessage == nil ? palette.text : palette.warning)
                if let secondaryMeta {
                    Text(secondaryMeta)
                        .foregroundStyle(palette.muted)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .lineLimit(1)
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
    let systemImage: String
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
        .help(title)
        .accessibilityLabel(title)
    }
}
