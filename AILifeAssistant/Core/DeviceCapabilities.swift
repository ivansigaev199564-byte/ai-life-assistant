import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Возможности, которые зависят от железа, а не от версии iOS.
///
/// Ключевой факт для этого проекта: iPhone 13 на iOS 26 имеет свежую систему,
/// но не имеет ни Action Button, ни Apple Intelligence. Поэтому проверять
/// только версию ОС недостаточно, нужны обе оси.
struct DeviceCapabilities: Sendable, Equatable {

    /// Идентификатор модели вида "iPhone16,1".
    let modelIdentifier: String

    /// Кнопка действия появилась в iPhone 15 Pro (iPhone16,1 и iPhone16,2).
    let hasActionButton: Bool

    /// Динамический остров появился в iPhone 14 Pro (iPhone15,2 и iPhone15,3).
    let hasDynamicIsland: Bool

    /// Apple Intelligence требует того же класса устройств, что и Action Button:
    /// iPhone 15 Pro и новее. Это не гарантия, что пользователь его включил,
    /// поэтому финальную проверку делает слой Foundation Models на Этапе 2.
    let supportsAppleIntelligenceHardware: Bool

    static let current = DeviceCapabilities(modelIdentifier: Self.rawModelIdentifier())

    init(modelIdentifier: String) {
        self.modelIdentifier = modelIdentifier
        let generation = Self.iPhoneGeneration(from: modelIdentifier)
        let isSimulator = modelIdentifier.hasPrefix("x86_64") || modelIdentifier.hasPrefix("arm64")

        switch generation {
        case .some(let device):
            // iPhone16,x это iPhone 15 Pro и вся линейка 16. Всё, что >= 16, имеет
            // Action Button; Pro-модели iPhone15,2 и iPhone15,3 его не имеют.
            self.hasActionButton = device.major >= 16
            self.supportsAppleIntelligenceHardware = device.major >= 16
            // Динамический остров: iPhone 14 Pro (15,2 / 15,3) и всё, что новее.
            self.hasDynamicIsland = device.major > 15
                || (device.major == 15 && device.minor >= 2)
        case .none:
            // Симулятор и неизвестные устройства: считаем возможности доступными
            // в симуляторе, чтобы можно было отлаживать интерфейс, и недоступными
            // на незнакомом железе, чтобы не обещать несуществующее.
            self.hasActionButton = isSimulator
            self.hasDynamicIsland = isSimulator
            self.supportsAppleIntelligenceHardware = isSimulator
        }
    }

    private struct DeviceNumber {
        let major: Int
        let minor: Int
    }

    private static func iPhoneGeneration(from identifier: String) -> DeviceNumber? {
        guard identifier.hasPrefix("iPhone") else { return nil }
        let numbers = identifier.dropFirst("iPhone".count).split(separator: ",")
        guard numbers.count == 2,
              let major = Int(numbers[0]),
              let minor = Int(numbers[1]) else { return nil }
        return DeviceNumber(major: major, minor: minor)
    }

    /// В симуляторе uname возвращает архитектуру хоста, поэтому сначала пробуем
    /// переменную окружения, которую подставляет сам симулятор.
    private static func rawModelIdentifier() -> String {
        if let simulator = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulator
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine
    }
}
