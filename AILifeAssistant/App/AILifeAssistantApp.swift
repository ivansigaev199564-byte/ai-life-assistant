import SwiftData
import SwiftUI

@main
struct AILifeAssistantApp: App {

    /// Единое окружение приложения. То же самое используют App Intents,
    /// поэтому кнопка действия и интерфейс работают с одним координатором.
    private let environment = AppEnvironment.shared

    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppEnvironment.shared.performStartupMaintenance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.coordinator)
                .environment(environment.settings)
                .environment(environment.permissions)
                .environment(environment.processingQueue)
                .environment(\.capabilities, environment.capabilities)
        }
        .modelContainer(environment.container)
        .onChange(of: scenePhase) { _, newPhase in
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
