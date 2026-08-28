import Foundation
import Observation
import UserNotifications

/// Куда вести человека, пришедшего снаружи.
///
/// Без этого нажатие на уведомление открывало приложение на общем списке:
/// телефон напомнил о звонке в банк, а человек оказывался в ленте и заново
/// искал глазами то, о чём ему только что сказали. Тем же путём приходят
/// ссылки из виджета.
@MainActor
@Observable
final class NotificationRouter {

    /// Ссылка, которую интерфейс ещё не открыл.
    private(set) var pendingLink: DeepLink?

    /// Делегат центра уведомлений хранится сильной ссылкой: сам центр
    /// держит его слабо и отпустил бы сразу после регистрации.
    private var delegate: NotificationDelegate?

    /// Ставит ссылку в очередь.
    func open(_ link: DeepLink) {
        pendingLink = link
    }

    /// Забирает ссылку: одно нажатие должно сработать ровно один раз.
    func consume() -> DeepLink? {
        defer { pendingLink = nil }
        return pendingLink
    }

    func clear() {
        pendingLink = nil
    }

    /// Подписывается на нажатия по уведомлениям.
    func register() {
        let delegate = NotificationDelegate(router: self)
        self.delegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }
}

/// Мост из UIKit-мира уведомлений в наблюдаемое состояние.
///
/// Отдельный тип, а не сам роутер: делегат обязан быть наследником NSObject,
/// и смешивать это с наблюдаемым состоянием значит зря усложнять оба.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    private let router: NotificationRouter

    init(router: NotificationRouter) {
        self.router = router
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let identifier = userInfo["reminderID"] as? String
        let router = self.router

        Task { @MainActor in
            if let identifier, let id = UUID(uuidString: identifier) {
                router.open(.reminder(id))
            }
            completionHandler()
        }
    }

    /// Уведомление, пришедшее при открытом приложении, всё равно показываем:
    /// иначе напоминание, поставленное «через пять минут», промолчит ровно
    /// тогда, когда человек сидит в приложении.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
