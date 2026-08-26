import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)

/// Описание живой активности записи.
///
/// Живёт в основном приложении, а не в расширении: активность запускается
/// приложением, а отображается виджетом, и оба должны видеть один тип.
struct CaptureActivityAttributes: ActivityAttributes {

    /// Меняющаяся часть: то, что видно в Динамическом острове прямо сейчас.
    struct ContentState: Codable, Hashable {
        /// Уровень сигнала 0...1 для индикатора.
        var audioLevel: Double
        /// Распознанный текст по ходу речи.
        var transcript: String
        /// Слышит ли микрофон речь.
        var isSpeaking: Bool
        /// Сколько идёт запись.
        var elapsed: TimeInterval
    }

    /// Неизменная часть: когда началась запись.
    var startedAt: Date
}

#endif
