import SwiftData
import SwiftUI

@main
struct AILifeAssistantApp: App {

    @Environment(\.scenePhase) private var scenePhase

    /// Окружение берётся лениво, а не хранится свойством.
    ///
    /// Под юнит-тестами приложение-хост не должен поднимать ни хранилище,
    /// ни аудио, ни интерфейс: всё это конкурирует с тестами за ресурсы
    /// симулятора и роняет прогон ещё до первой проверки.
    private var environment: AppEnvironment { AppEnvironment.shared }

    init() {
        guard !AppEnvironment.isRunningTests else { return }
        AppEnvironment.shared.performStartupMaintenance()
    }

    var body: some Scene {
        WindowGroup {
            if AppEnvironment.isRunningTests {
                Color.clear
            } else {
                RootView()
                    // Единый акцент на всё приложение: системные элементы
                    // управления должны совпадать по цвету с собственными.
                    .tint(DS.Palette.accent)
                    .environment(environment.coordinator)
                    .environment(environment.settings)
                    .environment(environment.permissions)
                    .environment(environment.processingQueue)
                    .environment(environment.undoService)
                    .environment(\.capabilities, environment.capabilities)
                    .modelContainer(environment.container)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard !AppEnvironment.isRunningTests else { return }

            // Тактильный движок останавливается в фоне, при возврате
            // его нужно поднять заново, иначе первый отклик потеряется.
            if newPhase == .active {
                HapticEngine.shared.prewarm()
                environment.permissions.refresh()
            }
        }
    }
}

/// Доступ к возможностям устройства из любого места иерархии представлений.
private struct CapabilitiesKey: EnvironmentKey {
    static let defaultValue = Capabilities.current
}

extension EnvironmentValues {
    var capabilities: Capabilities {
        get { self[CapabilitiesKey.self] }
        set { self[CapabilitiesKey.self] = newValue }
    }
}
