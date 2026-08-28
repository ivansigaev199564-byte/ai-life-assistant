import SwiftUI

/// Экран запертого приложения.
///
/// Показывает ровно столько, сколько нужно, чтобы человек понял, что от него
/// хотят, и ни строчки собственных записей: смысл замка в том, чтобы
/// содержимое не мелькнуло на экране до проверки.
struct LockScreenView: View {

    @Environment(AppLock.self) private var lock

    var body: some View {
        ZStack {
            DS.Palette.background.ignoresSafeArea()

            VStack(spacing: DS.Spacing.lg) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(DS.Palette.accent)

                VStack(spacing: DS.Spacing.xs) {
                    Text("Записи заперты")
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Palette.textPrimary)

                    Text("Разблокируйте, чтобы открыть свои записи.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Разблокировать", systemImage: "faceid")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, DS.Spacing.xl)

                if let failure = lock.lastFailure {
                    Text(failure)
                        .font(DS.Font.micro)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Spacing.lg)
                }
            }
        }
        // Проверка запускается сама: лишнее нажатие на пустом экране
        // никому не нужно.
        .task { await lock.unlock() }
    }
}
