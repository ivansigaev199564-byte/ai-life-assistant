import Foundation
import OSLog

/// Единая точка создания логгеров. Категории разделены, чтобы фильтровать
/// поток в Console.app по конкретной подсистеме.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.ivans.ailifeassistant"

    static let voice = Logger(subsystem: subsystem, category: "voice")
    static let intents = Logger(subsystem: subsystem, category: "intents")
    static let data = Logger(subsystem: subsystem, category: "data")
    static let capabilities = Logger(subsystem: subsystem, category: "capabilities")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Замер длительности критичных участков: путь от нажатия до haptic должен
    /// укладываться в 300 мс, и это единственный способ увидеть регресс.
    static func measure<T>(_ name: StaticString, logger: Logger, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            logger.debug("\(name, privacy: .public) занял \(elapsedMs, format: .fixed(precision: 1)) мс")
        }
        return try body()
    }
}
