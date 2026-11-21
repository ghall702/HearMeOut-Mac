import SwiftUI
import HearMeOutCore

// MARK: - Surfaces

/// Soft translucent card used throughout the app instead of grey utility panels.
struct GlassCard<Content: View>: View {
    @Environment(\.hmoTheme) private var theme
    var padding: CGFloat = 20
    var radius: CGFloat = 24
    var strong = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(strong ? theme.palette.surfaceStrong : theme.palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(theme.palette.stroke, lineWidth: 1))
                    .shadow(color: .black.opacity(theme.scheme == .dark ? 0.35 : 0.06), radius: 18, y: 8)
            }
    }
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive, record }
    @Environment(\.hmoTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    var kind: Kind = .secondary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        let p = theme.palette
        let fg: Color
        let bg: AnyShapeStyle
        switch kind {
        case .primary: fg = p.onAccent; bg = AnyShapeStyle(p.accent)
        case .record: fg = .white; bg = AnyShapeStyle(p.record)
        case .secondary: fg = p.text; bg = AnyShapeStyle(p.surfaceStrong)
        case .quiet: fg = p.secondaryText; bg = AnyShapeStyle(Color.clear)
        case .destructive: fg = p.record; bg = AnyShapeStyle(p.record.opacity(0.12))
        }
        return configuration.label
            .font(.system(size: large ? 15 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(fg)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 12 : 8)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(kind == .secondary ? p.stroke : .clear, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(_ kind: PillButtonStyle.Kind, large: Bool = false) -> PillButtonStyle { PillButtonStyle(kind: kind, large: large) }
}

/// Round icon button with a hover state.
struct IconButton: View {
    @Environment(\.hmoTheme) private var theme
    let symbol: String
    var size: CGFloat = 30
    var help: String
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint ?? theme.palette.text.opacity(0.8))
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? theme.palette.accentSoft : theme.palette.surface))
                .overlay(Circle().strokeBorder(theme.palette.stroke))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Avatars

struct AvatarView: View {
    @EnvironmentObject private var model: AppModel
    let account: Account?
    var size: CGFloat = 28
    var ring = false

    var body: some View {
        let theme = ThemeCatalog.theme(account?.themeId)
        let p = theme.palette(theme.preferred)
        ZStack {
            if let account, let img = model.avatars.image(for: account) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: p.wave.count > 1 ? p.wave : [p.accent, p.accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(account?.initials ?? "?")
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ring ? p.accent : Color.white.opacity(0.6), lineWidth: ring ? 2 : 1))
        .task(id: account?.id) { if let account { model.avatars.load(account) } }
        .accessibilityLabel(account?.title ?? "No account")
    }
}

// MARK: - Status

struct StatusPill: View {
    @Environment(\.hmoTheme) private var theme
    let text: String
    var symbol: String?
    var tone: Tone = .neutral
    var spinning = false

    enum Tone { case neutral, accent, success, warning, danger }

    var body: some View {
        let p = theme.palette
        let color: Color = {
            switch tone {
            case .neutral: return p.secondaryText
            case .accent: return p.accent
            case .success: return p.success
            case .warning: return p.warning
            case .danger: return p.record
            }
        }()
        HStack(spacing: 5) {
            if spinning {
                ProgressView().controlSize(.mini).tint(color)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            }
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

extension QueueItem {
    var statusTone: StatusPill.Tone {
        if needsAttention { return .danger }
        if isFinished { return lastError != nil ? .warning : .success }
        if upload == .ready { return .accent }
        return .neutral
    }

    var statusSymbol: String {
        if needsAttention { return "exclamationmark.triangle.fill" }
        if isFinished { return "checkmark.seal.fill" }
        switch upload {
        case .pending: return "clock"
        case .ticketed: return "arrow.up"
        case .uploaded: return "checkmark"
        case .ready: return "link"
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    @Environment(\.hmoTheme) private var theme
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(toast.isError ? theme.palette.record : theme.palette.accent)
            Text(toast.message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(theme.palette.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(theme.palette.stroke))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Waveforms

/// Bars from a list of 0…1 levels. Used for the live meter, review and playback.
struct WaveformBars: View {
    @Environment(\.hmoTheme) private var theme
    let levels: [Float]
    var progress: Double? = nil
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3
    var minHeight: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let w = geo.size.width
            let bw = max(1.5, min(barWidth, (w - CGFloat(max(0, count - 1)) * spacing) / CGFloat(max(1, count))))
            Canvas { ctx, size in
                let total = CGFloat(count) * bw + CGFloat(max(0, count - 1)) * spacing
                var x = (size.width - total) / 2
                for (i, v) in levels.enumerated() {
                    let h = max(minHeight, CGFloat(v) * size.height)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: bw, height: h)
                    let played = progress.map { Double(i) / Double(max(1, count)) <= $0 } ?? true
                    let shading: GraphicsContext.Shading = played
                        ? .linearGradient(Gradient(colors: theme.palette.wave), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
                        : .color(theme.palette.secondaryText.opacity(0.25))
                    ctx.fill(Path(roundedRect: rect, cornerRadius: bw / 2), with: shading)
                    x += bw + spacing
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Section headers

struct SectionTitle: View {
    @Environment(\.hmoTheme) private var theme
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(theme.titleFont(30, weight: .semibold)).foregroundStyle(theme.palette.text)
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(theme.palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Selectable chip used for filters and segmented choices.
struct Chip: View {
    @Environment(\.hmoTheme) private var theme
    let title: String
    var symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(selected ? theme.palette.onAccent : theme.palette.text.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(selected ? AnyShapeStyle(theme.palette.accent) : AnyShapeStyle(theme.palette.surface)))
            .overlay(Capsule().strokeBorder(selected ? .clear : theme.palette.stroke))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A selectable option card (used in onboarding and settings for modes and providers).
struct OptionCard: View {
    @Environment(\.hmoTheme) private var theme
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool
    var badge: String?
    var disabledReason: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selected ? theme.palette.onAccent : theme.palette.accent)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? theme.palette.accent : theme.palette.accentSoft))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(theme.palette.text)
                        if let badge { StatusPill(text: badge, tone: .accent) }
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(theme.palette.secondaryText).fixedSize(horizontal: false, vertical: true)
                    if let disabledReason {
                        Label(disabledReason, systemImage: "info.circle").font(.system(size: 11.5)).foregroundStyle(theme.palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? theme.palette.accent : theme.palette.secondaryText.opacity(0.4))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(selected ? theme.palette.accentSoft : (hovering ? theme.palette.surfaceStrong : theme.palette.surface)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(selected ? theme.palette.accent.opacity(0.6) : theme.palette.stroke, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
