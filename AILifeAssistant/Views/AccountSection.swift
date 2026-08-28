import SwiftUI

/// Аккаунт и синхронизация в настройках.
///
/// Слой синхронизации был написан целиком и оставался недостижимым: экрана
/// входа не существовало, поэтому включить её пользователь не мог никак,
/// а состояние отправки видел только разработчик в логах.
///
/// Секция показывается, только если бэкенд настроен: без него обещать
/// синхронизацию нечестно.
struct AccountSection: View {

    @Environment(AuthService.self) private var auth: AuthService?
    @Environment(SyncEngine.self) private var sync: SyncEngine?

    var body: some View {
        if let auth, let sync, SupabaseConfiguration.isConfigured {
            content(auth: auth, sync: sync)
        }
    }

    @ViewBuilder
    private func content(auth: AuthService, sync: SyncEngine) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: "Аккаунт")

            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    switch auth.state {
                    case .signedOut, .failed:
                        signedOutView(auth: auth)
                    case .signingIn:
                        HStack(spacing: DS.Spacing.xs) {
                            ProgressView().controlSize(.small)
                            Text("Вхожу")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    case .signedIn:
                        signedInView(auth: auth, sync: sync)
                    }

                    if case .failed(let message) = auth.state {
                        Text(message)
                            .font(DS.Font.micro)
                            .foregroundStyle(DS.Palette.danger)
                    }
                }
            }
        }
    }

    // MARK: Вход

    private func signedOutView(auth: AuthService) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Записи хранятся на устройстве. Вход нужен только для того, чтобы они появились на других ваших устройствах.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await auth.signIn() }
            } label: {
                Label("Войти через Apple", systemImage: "apple.logo")
                    .font(DS.Font.caption)
            }
            .foregroundStyle(DS.Palette.accent)
        }
    }

    // MARK: Состояние синхронизации

    private func signedInView(auth: AuthService, sync: SyncEngine) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text("Синхронизация")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                HStack(spacing: DS.Spacing.xxs) {
                    Circle()
                        .fill(statusColor(sync.state))
                        .frame(width: 6, height: 6)
                    Text(statusText(sync.state))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textPrimary)
                }
            }

            if let lastSyncedAt = sync.lastSyncedAt {
                detail("Последняя", lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
            }

            // Число неотправленных операций это единственный честный ответ
            // на вопрос «всё ли уехало».
            if sync.pendingCount > 0 {
                detail("Ждут отправки", String(sync.pendingCount))
            }

            if case .failed(let message) = sync.state {
                Text(message)
                    .font(DS.Font.micro)
                    .foregroundStyle(DS.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DS.Spacing.md) {
                Button {
                    Task { await sync.sync() }
                } label: {
                    Label("Синхронизировать", systemImage: "arrow.triangle.2.circlepath")
                        .font(DS.Font.caption)
                }
                .foregroundStyle(DS.Palette.accent)
                .disabled(sync.state == .syncing)

                Button(role: .destructive) {
                    auth.signOut()
                } label: {
                    Text("Выйти")
                        .font(DS.Font.caption)
                }
                .foregroundStyle(DS.Palette.danger)
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(DS.Font.micro)
                .foregroundStyle(DS.Palette.textTertiary)
            Spacer()
            Text(value)
                .font(DS.Font.micro)
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private func statusText(_ state: SyncEngine.State) -> String {
        switch state {
        case .idle: return "готово"
        case .syncing: return "идёт"
        case .offline: return "нет сети"
        case .failed: return "ошибка"
        }
    }

    private func statusColor(_ state: SyncEngine.State) -> Color {
        switch state {
        case .idle: return DS.Palette.success
        case .syncing: return DS.Palette.accent
        case .offline: return DS.Palette.textTertiary
        case .failed: return DS.Palette.danger
        }
    }
}
