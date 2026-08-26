import SwiftUI

/// Первый запуск.
///
/// Голосовой интерфейс не объясняет себя сам. Кнопка «Добавить задачу»
/// понятна без слов, кнопка «Говорить» нет: человек не знает, что сказать,
/// поймут ли его и что случится дальше. Поэтому первый экран показывает
/// не возможности приложения, а конкретные фразы, которые можно повторить
/// прямо сейчас.
struct OnboardingView: View {

    @Environment(PermissionsManager.self) private var permissions
    @Environment(\.capabilities) private var capabilities

    let onFinish: () -> Void

    @State private var page = 0

    /// Примеры фраз. Не выдуманные красивые, а бытовые: человек должен
    /// узнать в них то, что говорит сам.
    private static let examples: [(icon: String, phrase: String, result: String)] = [
        ("creditcard.fill", "Купил кофе за 300", "расход 300 ₽, категория «Еда»"),
        ("bell.fill", "Напомни завтра в девять позвонить в банк", "напоминание на 9:00"),
        ("checkmark.circle.fill", "Нужно заказать воду", "задача без срока"),
        ("text.alignleft", "Идея: сделать рассылку по вторникам", "заметка")
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcomePage.tag(0)
                examplesPage.tag(1)
                permissionsPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            footer
        }
        .background(DS.Palette.background)
    }

    // MARK: Страницы

    private var welcomePage: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            VoiceOrb(level: 0.35, isActive: true)

            VStack(spacing: DS.Spacing.sm) {
                Text("Скажите, и всё разложится по местам")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Приложение слушает обычную речь и само решает, что это было: трата, напоминание, задача или мысль.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.horizontal, DS.Spacing.lg)

            Spacer()
        }
    }

    private var examplesPage: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Spacer(minLength: DS.Spacing.lg)

            Text("Попробуйте сказать так")
                .font(DS.Font.title)
                .foregroundStyle(DS.Palette.textPrimary)
                .padding(.horizontal, DS.Spacing.md)

            VStack(spacing: DS.Spacing.sm) {
                ForEach(Self.examples, id: \.phrase) { example in
                    SurfaceCard(padding: DS.Spacing.sm + 2) {
                        HStack(spacing: DS.Spacing.sm) {
                            Image(systemName: example.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(DS.Palette.accent)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("«\(example.phrase)»")
                                    .font(DS.Font.entityTitle)
                                    .foregroundStyle(DS.Palette.textPrimary)

                                Text("станет: " + example.result)
                                    .font(DS.Font.micro)
                                    .foregroundStyle(DS.Palette.textSecondary)
                            }

                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.md)

            Text("Можно сказать несколько дел подряд одной фразой: приложение разложит их по отдельности.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textTertiary)
                .padding(.horizontal, DS.Spacing.md)

            Spacer()
        }
    }

    private var permissionsPage: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 52))
                .foregroundStyle(DS.Palette.accent)

            VStack(spacing: DS.Spacing.sm) {
                Text("Нужен доступ к микрофону")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Palette.textPrimary)

                Text("Речь распознаётся на устройстве и никуда не отправляется. Записи хранятся только у вас.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.horizontal, DS.Spacing.lg)

            if capabilities.device.hasActionButton {
                SurfaceCard(padding: DS.Spacing.sm + 2) {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "button.horizontal.top.press")
                            .font(.system(size: 18))
                            .foregroundStyle(DS.Palette.accent)

                        Text("Совет: назначьте кнопку действия на «Быструю запись», и запись будет начинаться одним нажатием.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
            }

            Spacer()
        }
    }

    // MARK: Нижняя кнопка

    private var footer: some View {
        VStack(spacing: DS.Spacing.xs) {
            Button {
                advance()
            } label: {
                Text(page == 2 ? "Разрешить и начать" : "Дальше")
            }
            .buttonStyle(PrimaryButtonStyle())

            if page < 2 {
                Button("Пропустить") { onFinish() }
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .frame(height: 44)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.md)
    }

    private func advance() {
        guard page == 2 else {
            withAnimation(DS.Motion.enter) { page += 1 }
            return
        }

        // Разрешение спрашивается на последнем шаге, когда уже понятно,
        // зачем оно: системное окно на пустом месте закрывают не глядя.
        Task {
            await permissions.requestAll()
            onFinish()
        }
    }
}

#Preview {
    OnboardingView(onFinish: {})
        .environment(PermissionsManager())
}
