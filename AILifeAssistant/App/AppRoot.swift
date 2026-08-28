import SwiftUI

/// Корень приложения: главный экран и всё, что обязано быть поверх него.
///
/// Отдельный слой нужен по одной причине: состояние записи должно быть
/// видно всегда, а не только когда открыт главный экран. Здесь же ловятся
/// внешние поводы что-то сделать: ссылка из уведомления или виджета
/// и запрос записи от кнопки Пункта управления.
struct AppRoot: View {

    let appEnvironment: AppEnvironment

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .overlayWindow(isPresented: needsOverlayWindow) {
                CaptureOverlayHost()
                    .environment(appEnvironment.coordinator)
                    .environment(appEnvironment.undoService)
                    .environment(appEnvironment.permissions)
                    .tint(DS.Palette.accent)
            }
            .onOpenURL { url in
                guard let link = DeepLink(url: url) else { return }
                appEnvironment.notificationRouter.open(link)
            }
            .task { startPendingCaptureIfNeeded() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                startPendingCaptureIfNeeded()
            }
    }

    /// Запертое приложение показывает только замок: содержимое не должно
    /// мелькнуть на экране до проверки.
    @ViewBuilder
    private var content: some View {
        if appEnvironment.appLock.isLocked {
            LockScreenView()
                .environment(appEnvironment.appLock)
        } else {
            RootView()
        }
    }

    /// Окно поверх нужно, пока идёт запись, висит ошибка или баннер отмены.
    private var needsOverlayWindow: Bool {
        if appEnvironment.coordinator.phase.isActive { return true }
        if case .failed = appEnvironment.coordinator.phase { return true }
        return appEnvironment.undoService.pending != nil
    }

    /// Кнопка Пункта управления не может включить микрофон сама: она только
    /// открывает приложение и оставляет просьбу. Прочитать её больше некому.
    private func startPendingCaptureIfNeeded() {
        guard SharedDefaults.consumeCaptureRequest() else { return }
        guard !appEnvironment.coordinator.phase.isActive else { return }

        Task {
            await appEnvironment.coordinator.start(source: .controlCenter)
        }
    }
}
