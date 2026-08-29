import Foundation
import LocalAuthentication
import Observation

/// Замок на приложение.
///
/// Дневник, траты и имена людей лежат за одним касанием: любой, у кого
/// в руках разблокированный телефон, читает всё. Замок необязательный,
/// потому что для голосового захвата важна скорость, и человек сам решает,
/// что для него дороже.
/// Чем подтверждают личность.
///
/// Протокол нужен ради проверяемости: тест с настоящим LAContext уходит
/// в системный диалог и висит до таймаута, а прогон из-за одного такого
/// теста растягивается с пятнадцати секунд до пяти минут.
protocol AuthenticationContext: Sendable {
    func canAuthenticate() -> Bool
    func authenticate(reason: String) async throws -> Bool
}

extension LAContext: @unchecked Sendable {}

extension LAContext: AuthenticationContext {

    func canAuthenticate() -> Bool {
        canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async throws -> Bool {
        localizedCancelTitle = "Отмена"
        return try await evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}

@MainActor
@Observable
final class AppLock {

    /// Через сколько секунд после ухода в фон замок защёлкивается.
    ///
    /// Мгновенная блокировка мешает: между записью голоса и ответом на
    /// звонок проходит несколько секунд, и требовать Face ID каждый раз
    /// значит заставить человека отключить замок совсем.
    static let grace: TimeInterval = 60

    private(set) var isLocked: Bool
    private(set) var lastFailure: String?

    private let defaults: UserDefaults
    private let contextFactory: @Sendable () -> AuthenticationContext
    private var backgroundedAt: Date?

    private static let enabledKey = "security.appLock.enabled"

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            isLocked = isEnabled ? isLocked : false
        }
    }

    /// Доступна ли биометрия или код-пароль на этом устройстве.
    var isAvailable: Bool {
        contextFactory().canAuthenticate()
    }

    init(
        defaults: UserDefaults = .standard,
        contextFactory: @escaping @Sendable () -> AuthenticationContext = { LAContext() }
    ) {
        self.defaults = defaults
        self.contextFactory = contextFactory
        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        // При запуске приложение заперто сразу, если замок включён:
        // иначе первый кадр покажет ленту записей до проверки.
        self.isLocked = enabled
    }

    // MARK: Жизненный цикл

    func applicationDidEnterBackground(at date: Date = .now) {
        guard isEnabled else { return }
        backgroundedAt = date
    }

    func applicationWillEnterForeground(at date: Date = .now) {
        guard isEnabled, let backgroundedAt else { return }

        if date.timeIntervalSince(backgroundedAt) >= Self.grace {
            isLocked = true
        }
        self.backgroundedAt = nil
    }

    // MARK: Проверка

    /// Спрашивает Face ID или код-пароль.
    ///
    /// Политика именно deviceOwnerAuthentication, а не биометрия отдельно:
    /// иначе человек с мокрыми руками или в маске остаётся без доступа
    /// к собственным записям.
    func unlock() async {
        guard isLocked else { return }

        let context = contextFactory()

        // Проверить нечем: код-пароль сняли, биометрия сломалась, устройство
        // не то. Держать человека снаружи собственных записей в этом случае
        // нельзя: настройки, где выключается замок, сами за замком, и выхода
        // из положения не осталось бы вовсе.
        guard context.canAuthenticate() else {
            Log.ui.notice("Замок снят: устройству нечем подтвердить личность")
            isEnabled = false
            isLocked = false
            lastFailure = nil
            return
        }

        do {
            let success = try await context.authenticate(
                reason: "Разблокируйте, чтобы открыть свои записи"
            )
            isLocked = !success
            lastFailure = nil
        } catch {
            lastFailure = error.localizedDescription
            Log.ui.notice("Разблокировка не удалась: \(error.localizedDescription)")
        }
    }
}
