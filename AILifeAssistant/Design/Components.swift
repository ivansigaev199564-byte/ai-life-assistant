import SwiftUI

// MARK: Поверхности

/// Карточка: базовая поверхность для всего содержимого.
///
/// В тёмной теме тень бесполезна, её просто не видно, поэтому глубина
/// задаётся разницей яркости и тонкой границей. В светлой добавляется
/// мягкая тень.
struct SurfaceCard<Content: View>: View {

    @Environment(\.colorScheme) private var colorScheme

    var padding: CGFloat = DS.Spacing.md
    var isHighlighted = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(DS.Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isHighlighted ? DS.Palette.accent.opacity(0.5) : DS.Palette.border,
                        lineWidth: isHighlighted ? 1.5 : 1
                    )
            }
            .shadow(
                color: colorScheme == .light ? .black.opacity(0.05) : .clear,
                radius: 14,
                y: 6
            )
    }
}

// MARK: Сущности

/// Компактная плашка сущности: значок, суть, значение.
///
/// Цвет несёт смысл: зелёное это деньги, янтарное это время, синее это
/// действие. Пользователь узнаёт тип записи раньше, чем прочитает текст.
struct EntityChip: View {

    let kind: ParsedItemKind
    let title: String
    var value: String?
    var needsReview = false

    private var tint: Color { DS.EntityColor.forKind(kind) }

    private var symbol: String {
        switch kind {
        case .expense: return "creditcard.fill"
        case .reminder: return "bell.fill"
        case .task: return "checkmark.circle.fill"
        case .note: return "text.alignleft"
        }
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)

            Text(title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textPrimary)
                .lineLimit(1)

            if let value {
                Text(value)
                    .font(DS.Font.amount)
                    .foregroundStyle(tint)
            }

            if needsReview {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Palette.warning)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xxs + 2)
        .background {
            Capsule().fill(tint.opacity(0.12))
        }
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
        }
    }
}

/// Индикатор состояния обработки записи.
struct StatusBadge: View {

    let status: CaptureStatus

    private var tint: Color {
        switch status {
        case .pending: return DS.Palette.textTertiary
        case .processing: return DS.Palette.accent
        case .synced: return DS.Palette.success
        case .failed: return DS.Palette.danger
        }
    }

    var body: some View {
        Group {
            switch status {
            case .processing:
                // Пульсация показывает, что работа идёт, без спиннера,
                // который в списке выглядит навязчиво.
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .modifier(PulseEffect())
            case .pending:
                Circle()
                    .strokeBorder(tint, lineWidth: 1.2)
                    .frame(width: 6, height: 6)
            case .synced:
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 10, height: 10)
        // Статус входит в общую подпись строки, отдельно эта точка
        // для VoiceOver только шум.
        .accessibilityHidden(true)
    }
}

/// Мягкая пульсация для индикатора работы.
struct PulseEffect: ViewModifier {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.35 : 0.85)
            .opacity(isPulsing ? 0.5 : 1)
            .onAppear {
                // При запрете анимаций индикатор остаётся статичным:
                // состояние всё равно понятно по цвету и форме.
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// MARK: Кнопки

/// Главная кнопка действия.
struct PrimaryButtonStyle: ButtonStyle {

    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isProminent ? .white : DS.Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                if isProminent {
                    Capsule().fill(DS.recordingGradient)
                } else {
                    Capsule().fill(DS.Palette.surfaceElevated)
                }
            }
            .overlay {
                if !isProminent {
                    Capsule().strokeBorder(DS.Palette.border, lineWidth: 1)
                }
            }
            // Нажатие отзывается сжатием: это единственная обратная связь,
            // которую видно, пока палец закрывает саму кнопку.
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(DS.Motion.tap, value: configuration.isPressed)
    }
}

/// Круглая кнопка для панели инструментов.
///
/// Минимум сорок четыре пункта: это нижняя граница цели, в которую
/// человек попадает пальцем, не глядя и на ходу. Меньше выглядит
/// изящнее и промахивается чаще.
struct CircleButtonStyle: ButtonStyle {

    var size: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(DS.Palette.textPrimary)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .background {
                Circle().fill(DS.Palette.surfaceElevated)
            }
            .overlay {
                Circle().strokeBorder(DS.Palette.border, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(DS.Motion.tap, value: configuration.isPressed)
    }
}

// MARK: Заголовки и пустые состояния

/// Заголовок экрана в едином стиле.
struct ScreenHeader: View {

    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> AnyView

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> AnyView = { AnyView(EmptyView()) }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.display)
                    .foregroundStyle(DS.Palette.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }

            Spacer(minLength: DS.Spacing.sm)
            trailing()
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.xs)
        .padding(.bottom, DS.Spacing.sm)
    }
}

/// Пустое состояние: значок, заголовок, подсказка.
struct EmptyStateView: View {

    let symbol: String
    let title: String
    let message: String

    @State private var appeared = false

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(DS.Palette.accent.opacity(0.1))
                    .frame(width: 84, height: 84)

                Image(systemName: symbol)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(DS.Palette.accent)
            }
            .scaleEffect(appeared ? 1 : 0.8)
            .opacity(appeared ? 1 : 0)

            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Palette.textPrimary)

            Text(message)
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, DS.Spacing.lg)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xxl)
        .onAppear {
            withAnimation(DS.Motion.enter.delay(0.05)) { appeared = true }
        }
    }
}

/// Заголовок раздела внутри экрана.
struct SectionLabel: View {

    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.micro)
            .kerning(0.8)
            .foregroundStyle(DS.Palette.textTertiary)
            .padding(.horizontal, DS.Spacing.xxs)
    }
}
