import AVFoundation
import Foundation

/// Управление аудиосессией: активация под запись, обработка прерываний
/// и смены маршрута (наушники, звонок, будильник).
///
/// Отдельный тип, потому что ошибки аудиосессии это половина всех проблем
/// с записью на реальных устройствах, и их нужно ловить в одном месте.
@MainActor
final class AudioSessionManager {

    /// Причина принудительной остановки записи снаружи.
    enum Interruption: Sendable {
        case began
        case ended(shouldResume: Bool)
        case routeChanged
        case mediaServicesReset
    }

    /// Обращение к общей аудиосессии ленивое: её захват в конструкторе
    /// поднимает аудиостек на каждое создание менеджера, а в тестах
    /// координатор создаётся десятки раз подряд.
    private var session: AVAudioSession { .sharedInstance() }
    /// deinit не изолирован главным актором, поэтому список наблюдателей
    /// помечен как доступный вне изоляции: он только создаётся и очищается.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// Вызывается, когда систему прервали. Координатор захвата на это
    /// закрывает сессию и сохраняет то, что успел распознать.
    var onInterruption: ((Interruption) -> Void)?

    /// Пишет ли микрофон через Bluetooth-гарнитуру.
    ///
    /// Профиль HFP отдаёт узкополосный и заметно более тихий сигнал, чем
    /// встроенный микрофон, а режим .measurement отключает системную
    /// обработку. Пороги детектора для такого маршрута приходится опускать.
    var isUsingBluetoothInput: Bool {
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE]
        return AVAudioSession.sharedInstance().currentRoute.inputs
            .contains { bluetooth.contains($0.portType) }
    }

    /// - Parameter observesSystemEvents: подписываться ли на прерывания
    ///   и смену маршрута. В тестах это лишнее: наблюдатели держат
    ///   аудиостек, который тестам логики не нужен вовсе.
    init(observesSystemEvents: Bool = true) {
        guard observesSystemEvents else { return }
        registerObservers()
    }

    deinit {
        // Снимаем наблюдателей синхронно: NotificationCenter потокобезопасен.
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Готовит сессию под запись с распознаванием.
    ///
    /// Режим `.measurement` отключает системную обработку сигнала, из-за
    /// которой уровни скачут и детектор тишины срабатывает невпопад.
    func activateForRecording() throws {
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            Log.voice.error("Не удалось активировать аудиосессию: \(error.localizedDescription)")
            throw AppError.audioSessionFailed(underlying: error.localizedDescription)
        }
    }

    /// Освобождает сессию, возвращая звук другим приложениям.
    func deactivate() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Деактивация часто падает, если звук ещё доигрывает. Это не ошибка
            // пользовательского сценария, поэтому только пишем в лог.
            Log.voice.debug("Аудиосессия не деактивирована: \(error.localizedDescription)")
        }
    }

    /// Частота дискретизации, которую реально отдаёт железо.
    var sampleRate: Double { session.sampleRate }

    private func registerObservers() {
        let center = NotificationCenter.default

        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let info = notification.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

            MainActor.assumeIsolated {
                switch type {
                case .began:
                    Log.voice.notice("Аудиосессия прервана")
                    self.onInterruption?(.began)
                case .ended:
                    let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                        AVAudioSession.InterruptionOptions(rawValue: $0)
                    }
                    let shouldResume = options?.contains(.shouldResume) ?? false
                    self.onInterruption?(.ended(shouldResume: shouldResume))
                @unknown default:
                    break
                }
            }
        }

        let route = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

            // Появление нового устройства ввода не менее важно, чем пропажа
            // старого: гарнитура, подключившаяся в машине посреди фразы,
            // меняет формат потока, а отвод остаётся настроенным на прежний.
            // Раньше такие события молча отбрасывались, и запись либо
            // обрывалась тишиной, либо писалась в пустоту.
            let handled: Set<AVAudioSession.RouteChangeReason> = [
                .oldDeviceUnavailable,
                .newDeviceAvailable,
                .override,
                .routeConfigurationChange,
                .categoryChange
            ]
            guard handled.contains(reason) else { return }

            MainActor.assumeIsolated {
                Log.voice.notice("Маршрут звука изменился: \(reason.rawValue)")
                self.onInterruption?(.routeChanged)
            }
        }

        let reset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                Log.voice.error("Медиасервисы перезапущены, аудиограф недействителен")
                self.onInterruption?(.mediaServicesReset)
            }
        }

        observers = [interruption, route, reset]
    }
}
