import CoreHaptics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Тактильная обратная связь.
///
/// Главное требование продукта: отклик на нажатие кнопки действия не позже
/// 300 мс. Поэтому движок прогревается при запуске приложения, а сам вызов
/// не делает ничего тяжелее проигрывания готового паттерна.
@MainActor
final class HapticEngine {

    static let shared = HapticEngine()

    private var engine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// Генераторы UIKit держим готовыми: их prepare занимает до сотни
    /// миллисекунд, и делать это в момент нажатия поздно.
    #if canImport(UIKit)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()
    private let selectionGenerator = UISelectionFeedbackGenerator()
    #endif

    private init() {}

    /// Прогрев. Вызывается при запуске приложения и при возврате из фона.
    func prewarm() {
        #if canImport(UIKit)
        impactMedium.prepare()
        impactLight.prepare()
        notification.prepare()
        selectionGenerator.prepare()
        #endif

        guard supportsHaptics else { return }

        if engine == nil {
            do {
                let engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
                engine.isAutoShutdownEnabled = true

                // Движок останавливается при звонке или уходе в фон,
                // после чего его нужно поднимать заново.
                engine.stoppedHandler = { reason in
                    Log.ui.debug("Тактильный движок остановлен: \(reason.rawValue)")
                }
                engine.resetHandler = { [weak engine] in
                    do {
                        try engine?.start()
                    } catch {
                        Log.ui.error("Не удалось перезапустить тактильный движок: \(error.localizedDescription)")
                    }
                }
                self.engine = engine
            } catch {
                Log.ui.error("Тактильный движок недоступен: \(error.localizedDescription)")
                return
            }
        }

        do {
            try engine?.start()
        } catch {
            Log.ui.debug("Тактильный движок не стартовал: \(error.localizedDescription)")
        }
    }

    /// Начало записи: короткий чёткий удар. Это тот самый отклик,
    /// по которому пользователь понимает, что можно говорить.
    func captureStarted() {
        #if canImport(UIKit)
        impactMedium.impactOccurred(intensity: 1.0)
        impactMedium.prepare()
        #endif
    }

    /// Запись остановлена и сохраняется.
    func captureStopped() {
        #if canImport(UIKit)
        impactLight.impactOccurred(intensity: 0.7)
        impactLight.prepare()
        #endif
    }

    /// Захват сохранён: двойной мягкий отклик, отличимый от старта на ощупь.
    func captureSaved() {
        if playDoubleTap() { return }
        #if canImport(UIKit)
        notification.notificationOccurred(.success)
        notification.prepare()
        #endif
    }

    func captureFailed() {
        #if canImport(UIKit)
        notification.notificationOccurred(.error)
        notification.prepare()
        #endif
    }

    func selectionChanged() {
        #if canImport(UIKit)
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
        #endif
    }

    /// Двойной удар через Core Haptics. Возвращает false, если железо
    /// или движок недоступны, чтобы вызвать запасной путь UIKit.
    private func playDoubleTap() -> Bool {
        guard supportsHaptics, let engine else { return false }

        let first = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            ],
            relativeTime: 0
        )
        let second = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
            ],
            relativeTime: 0.09
        )

        do {
            let pattern = try CHHapticPattern(events: [first, second], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            Log.ui.debug("Паттерн не проигран: \(error.localizedDescription)")
            return false
        }
    }
}
