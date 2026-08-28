import Foundation
import Network
import Observation

/// Состояние сети.
///
/// Приложение офлайн-первое: запись сохраняется и разбирается локально
/// в любом случае, а синхронизация ждёт связи. Монитор нужен, чтобы
/// не долбиться в сеть впустую и чтобы возобновлять отправку сразу,
/// как только связь появилась.
@MainActor
@Observable
final class NetworkMonitor {

    private(set) var isOnline = true
    /// Сеть дорогая: сотовая связь или роуминг. Тяжёлые операции вроде
    /// загрузки модели распознавания в таком режиме лучше не начинать.
    private(set) var isExpensive = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "network.monitor")

    /// Кого разбудить, когда связь появилась после перерыва.
    ///
    /// Список, а не одно замыкание: подписчиков двое, синхронизация
    /// и очередь разбора, и раньше второй просто затирал первого.
    private var onlineHandlers: [() -> Void] = []

    func whenBecameOnline(_ handler: @escaping () -> Void) {
        onlineHandlers.append(handler)
    }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }

                let wasOffline = !self.isOnline
                self.isOnline = path.status == .satisfied
                self.isExpensive = path.isExpensive

                if wasOffline, self.isOnline {
                    Log.data.notice("Связь восстановлена, возобновляю отложенное")
                    self.onlineHandlers.forEach { $0() }
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
