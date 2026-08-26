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

    /// Вызывается, когда связь появилась после перерыва.
    var onBecameOnline: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }

                let wasOffline = !self.isOnline
                self.isOnline = path.status == .satisfied
                self.isExpensive = path.isExpensive

                if wasOffline, self.isOnline {
                    Log.data.notice("Связь восстановлена, возобновляю синхронизацию")
                    self.onBecameOnline?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
