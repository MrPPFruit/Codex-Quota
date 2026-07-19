import CodexUsageCore
import SwiftUI

@MainActor
public final class UsageStore: ObservableObject {
    @Published public var snapshot: UsageSnapshot

    public init(snapshot: UsageSnapshot = .unavailable) {
        self.snapshot = snapshot
    }

    public func observe(_ snapshots: AsyncStream<UsageSnapshot>) async {
        for await snapshot in snapshots { self.snapshot = snapshot }
    }
}

public enum BubbleAppearancePreset: String, CaseIterable, Sendable {
    case clear
    case soft

    public static let storageKey = "codex-quota.bubble-appearance-preset"
    public static let defaultValue = Self.soft

    public static func resolve(storedRawValue: String?) -> Self {
        storedRawValue.flatMap(Self.init(rawValue:)) ?? defaultValue
    }

    public struct Parameters: Sendable, Equatable {
        public let whiteLayerOpacity: Double
        public let colorLayerOpacity: Double
        public let saturation: Double
        public let brightness: Double
        public let blurRadius: Double
    }

    public var displayName: String {
        switch self {
        case .clear: "清透"
        case .soft: "柔彩"
        }
    }

    public var parameters: Parameters {
        switch self {
        case .clear:
            Parameters(
                whiteLayerOpacity: 0.20,
                colorLayerOpacity: 0.40,
                saturation: 1.70,
                brightness: 0.10,
                blurRadius: 7.0
            )
        case .soft:
            Parameters(
                whiteLayerOpacity: 0.70,
                colorLayerOpacity: 0.60,
                saturation: 1.60,
                brightness: -0.10,
                blurRadius: 8.0
            )
        }
    }
}

public struct UsageOverlayView: View {
    @ObservedObject private var store: UsageStore
    @ObservedObject private var expansionStore: OverlayExpansionStore
    @AppStorage(BubbleAppearancePreset.storageKey)
    private var bubbleAppearanceRawValue = BubbleAppearancePreset.defaultValue.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let onHoverChange: (Bool, Bool) -> Void
    private let reduceMotionOverride: Bool?
    private let reduceTransparencyOverride: Bool?
    private let forcedExpanded: Bool?
    @State private var flowAngle = Angle.zero

    public init(
        store: UsageStore,
        expansionStore: OverlayExpansionStore,
        reduceMotionOverride: Bool? = nil,
        reduceTransparencyOverride: Bool? = nil,
        forcedExpanded: Bool? = nil,
        onHoverChange: @escaping (Bool, Bool) -> Void = { _, _ in }
    ) {
        self.store = store
        self.expansionStore = expansionStore
        self.reduceMotionOverride = reduceMotionOverride
        self.reduceTransparencyOverride = reduceTransparencyOverride
        self.forcedExpanded = forcedExpanded
        self.onHoverChange = onHoverChange
    }

    public var body: some View {
        let style = UsageSemanticStyle(
            fiveHourPercent: store.snapshot.fiveHour.remainingPercent,
            weeklyPercent: store.snapshot.weekly.remainingPercent
        )
        let collapsedPresentation = CollapsedUsagePresentation.select(from: store.snapshot)

        GeometryReader { geometry in
            let shape = AnyShape(RoundedRectangle(
                cornerRadius: cornerRadius(for: geometry.size),
                style: .continuous
            ))

            ZStack {
                surface(shape: shape)
                ZStack {
                    collapsed(collapsedPresentation)
                        .opacity(isExpanded ? 0 : 1)
                        .animation(collapsedContentAnimation, value: isExpanded)
                        .accessibilityHidden(isExpanded)
                    expanded(style: style)
                        .opacity(isExpanded ? 1 : 0)
                        .animation(expandedContentAnimation, value: isExpanded)
                        .accessibilityHidden(!isExpanded)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipShape(shape)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovered in
            guard forcedExpanded == nil else { return }
            onHoverChange(hovered, !motionIsReduced)
        }
        .onAppear {
            restartColorFlow()
        }
        .onChange(of: motionIsReduced) { _, _ in
            restartColorFlow()
        }
    }

    private func restartColorFlow() {
        let transaction = Transaction(animation: nil)
        withTransaction(transaction) { flowAngle = .zero }
        guard !motionIsReduced else { return }
        withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) {
            flowAngle = .degrees(360)
        }
    }

    @ViewBuilder
    private func surface(shape: AnyShape) -> some View {
        let solidFallback = Color(red: 0.94, green: 0.95, blue: 0.97)
        ZStack {
            if transparencyIsReduced {
                shape.fill(solidFallback)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(
                        .clear.interactive(!motionIsReduced),
                        in: shape
                    )
                shape.fill(.white.opacity(bubbleAppearance.whiteLayerOpacity))
                siriBubbleOptics(shape: shape)
            }
        }
    }

    private func siriBubbleOptics(shape: AnyShape) -> some View {
        shape
            .fill(
                AngularGradient(
                    colors: bubbleColors,
                    center: .center,
                    startAngle: flowAngle,
                    endAngle: .degrees(flowAngle.degrees + 360)
                )
            )
            .saturation(bubbleAppearance.saturation)
            .brightness(bubbleAppearance.brightness)
            .blur(radius: CGFloat(bubbleAppearance.blurRadius))
            .opacity(bubbleAppearance.colorLayerOpacity)
            .mask(shape)
    }

    private var bubbleAppearance: BubbleAppearancePreset.Parameters {
        BubbleAppearancePreset.resolve(storedRawValue: bubbleAppearanceRawValue).parameters
    }

    private var bubbleColors: [Color] {
        [
            Color(red: 0.18, green: 0.88, blue: 1.00),
            Color(red: 0.32, green: 0.48, blue: 1.00),
            Color(red: 0.72, green: 0.34, blue: 1.00),
            Color(red: 1.00, green: 0.38, blue: 0.72),
            Color(red: 0.18, green: 0.88, blue: 1.00),
        ]
    }

    private func collapsed(_ presentation: CollapsedUsagePresentation) -> some View {
        VStack(spacing: 3) {
            percentageText(presentation.window, level: presentation.semanticLevel, size: 19)
                .offset(y: 2)
            Text(presentation.compactLabel)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(neutralSecondary)
        }
        .offset(y: 3)
        .padding(.horizontal, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }

    private func expanded(style: UsageSemanticStyle) -> some View {
        VStack(spacing: 0) {
            compactUsageRow(title: "5h", window: store.snapshot.fiveHour, level: style.fiveHour)
            Divider()
                .overlay(neutralPrimary.opacity(0.12))
                .padding(.horizontal, 8)
            compactUsageRow(title: "周", window: store.snapshot.weekly, level: style.weekly)
        }
        .padding(.vertical, 4)
    }

    private func compactUsageRow(title: String, window: UsageWindow, level: UsageSemanticLevel) -> some View {
        let accessibility = UsageAccessibilityDescriptor(window: window)
        let reset = CompactResetPresentation.make(for: window)
        return HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(neutralPrimary)
                    .frame(width: 17, alignment: .leading)
                percentageText(window, level: level, size: 14)
                    .frame(minWidth: 30, alignment: .leading)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 0) {
                Text(reset.date)
                Text(reset.time)
            }
            .font(.system(size: 9, weight: .regular))
            .foregroundStyle(neutralSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.84)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
    }

    private func percentageText(_ window: UsageWindow, level: UsageSemanticLevel, size: CGFloat) -> some View {
        return Text(UsageVisibleQuotaText.make(for: window))
            .font(QuotaNumberFont.font(size: size))
            .foregroundStyle(textColor(for: level))
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .shadow(
                color: digitContrastEdge,
                radius: 0,
                x: -0.65,
                y: 0
            )
            .shadow(
                color: digitContrastEdge,
                radius: 0,
                x: 0.65,
                y: 0
            )
            .shadow(
                color: digitContrastEdge,
                radius: 0,
                x: 0,
                y: -0.65
            )
            .shadow(
                color: digitContrastEdge,
                radius: 0,
                x: 0,
                y: 0.65
            )
            .shadow(
                color: digitContrastShadow,
                radius: 1.1,
                x: 0,
                y: 0.6
            )
    }

    private func textColor(for level: UsageSemanticLevel) -> Color {
        switch level {
        case .sufficient: Color(red: 65.0 / 255.0, green: 199.0 / 255.0, blue: 89.0 / 255.0)
        case .attention: Color(red: 249.0 / 255.0, green: 200.0 / 255.0, blue: 0.0)
        case .urgent: Color(red: 244.0 / 255.0, green: 92.0 / 255.0, blue: 95.0 / 255.0)
        case .unavailable: neutralSecondary
        @unknown default: level.color
        }
    }

    private var neutralPrimary: Color {
        Color(red: 0.10, green: 0.11, blue: 0.15).opacity(0.92)
    }

    private var neutralSecondary: Color {
        Color(red: 0.18, green: 0.20, blue: 0.27).opacity(0.68)
    }

    private var digitContrastEdge: Color {
        Color(red: 0.02, green: 0.03, blue: 0.06).opacity(0.10)
    }

    private var digitContrastShadow: Color {
        Color.black.opacity(0.30)
    }

    private var motionIsReduced: Bool { reduceMotionOverride ?? reduceMotion }
    private var transparencyIsReduced: Bool { reduceTransparencyOverride ?? reduceTransparency }

    private func cornerRadius(for size: CGSize) -> CGFloat {
        let expansionProgress = min(max((size.height - 52) / (78 - 52), 0), 1)
        return 26 - (4 * expansionProgress)
    }

    private var collapsedContentAnimation: Animation? {
        guard !motionIsReduced else { return nil }
        return isExpanded
            ? .easeOut(duration: 0.07)
            : .easeOut(duration: 0.10).delay(0.07)
    }

    private var expandedContentAnimation: Animation? {
        guard !motionIsReduced else { return nil }
        return isExpanded
            ? .easeOut(duration: 0.10).delay(0.07)
            : .easeOut(duration: 0.07)
    }

    private var isExpanded: Bool { forcedExpanded ?? expansionStore.isExpanded }
}
