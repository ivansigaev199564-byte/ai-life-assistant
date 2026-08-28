import SwiftUI

/// Всё, что должно быть видно поверх любого экрана: запись, ошибка записи
/// и баннер отмены.
///
/// Живёт в отдельном окне, поэтому не зависит от того, открыт ли сейчас
/// лист настроек, карточка записи или системное меню. Раньше всё это
/// пряталось за первым же открытым листом, а микрофон продолжал писать.
struct CaptureOverlayHost: View {

    @Environment(CaptureCoordinator.self) private var coordinator
    @Environment(UndoService.self) private var undoService
    @Environment(PermissionsManager.self) private var permissions

    var body: some View {
        ZStack(alignment: .bottom) {
            if coordinator.phase.isActive {
                RecordingOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            banners
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(DS.Motion.phase, value: coordinator.phase)
        .animation(DS.Motion.enter, value: undoService.pending?.id)
    }

    /// Баннеры показываются только вне записи: во время записи экран занят
    /// оверлеем, и добавлять к нему что-то ещё незачем.
    @ViewBuilder
    private var banners: some View {
        if !coordinator.phase.isActive {
            VStack(spacing: DS.Spacing.xs) {
                if case .failed(let error) = coordinator.phase {
                    errorBanner(error)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let pending = undoService.pending {
                    UndoBanner(
                        action: pending,
                        onUndo: { undoService.undo() },
                        onDismiss: { undoService.dismiss() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            // Кнопка записи занимает низ главного экрана: баннер встаёт
            // над ней, а не поверх неё.
            .padding(.bottom, 96)
        }
    }

    private func errorBanner(_ error: AppError) -> some View {
        SurfaceCard(padding: DS.Spacing.sm) {
            HStack(alignment: .top, spacing: DS.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Palette.warning)

                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(error.errorDescription ?? "Ошибка")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textPrimary)

                    if error.suggestsSystemSettings {
                        Button("Открыть настройки") {
                            permissions.openSystemSettings()
                        }
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.accent)
                    }
                }

                Spacer(minLength: DS.Spacing.xs)

                // Баннер ошибки раньше нельзя было закрыть: он висел до
                // следующей удачной записи и мешал читать ленту.
                Button {
                    coordinator.dismissError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть сообщение")
            }
        }
    }
}
