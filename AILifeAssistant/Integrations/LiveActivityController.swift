import Foundation
import Observation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Управление живой активностью записи.
///
/// Динамический остров решает конкретную проблему: пользователь нажал
/// кнопку действия и говорит, глядя не в экран, а на дорогу или собеседника.
/// Остров даёт периферийным зрением понять, что запись идёт и микрофон
/// слышит, не требуя смотреть в приложение.
@MainActor
@Observable
final class LiveActivityController {

    private(set) var isActive = false

    #if canImport(ActivityKit)
    private var activity: Activity<CaptureActivityAttributes>?
    #endif

    /// Доступны ли живые активности: нужен и Динамический остров,
    /// и разрешение пользователя, которое он мог отозвать в настройках.
    var isAvailable: Bool {
        #if canImport(ActivityKit)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    // MARK: Жизненный цикл

    func start() {
        #if canImport(ActivityKit)
        guard isAvailable, activity == nil else { return }

        let attributes = CaptureActivityAttributes(startedAt: .now)
        let initialState = CaptureActivityAttributes.ContentState(
            audioLevel: 0,
            transcript: "",
            isSpeaking: false,
            elapsed: 0
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: initialState, staleDate: nil)
            )
            isActive = true
        } catch {
            // Отказ в активности не должен мешать записи: она и так идёт.
            Log.ui.notice("Живая активность не запущена: \(error.localizedDescription)")
        }
        #endif
    }

    /// Обновляет содержимое острова.
    ///
    /// Вызывается на каждом замере уровня, поэтому обновления намеренно
    /// редкие: система ограничивает частоту, а слишком частые запросы
    /// она попросту отбрасывает.
    func update(level: Float, transcript: String, isSpeaking: Bool, elapsed: TimeInterval) {
        #if canImport(ActivityKit)
        guard let activity else { return }

        let state = CaptureActivityAttributes.ContentState(
            audioLevel: Double(min(1, max(0, level))),
            // Длинную расшифровку обрезаем: в остров всё равно поместится
            // только хвост, а гонять килобайты текста незачем.
            transcript: String(transcript.suffix(120)),
            isSpeaking: isSpeaking,
            elapsed: elapsed
        )

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        #endif
    }

    func stop() {
        #if canImport(ActivityKit)
        guard let activity else { return }
        let final = activity

        Task {
            // Мгновенное закрытие: остров не должен висеть после того,
            // как запись сохранена.
            await final.end(nil, dismissalPolicy: .immediate)
        }

        self.activity = nil
        isActive = false
        #endif
    }
}
