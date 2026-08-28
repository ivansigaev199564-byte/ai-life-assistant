import Foundation

/// Ссылки внутрь приложения.
///
/// Уведомление, виджет и системные интеграции должны открывать не
/// «приложение вообще», а ровно то дело, о котором они говорят. Иначе
/// человек, нажавший на напоминание, оказывается в общем списке и заново
/// ищет глазами то, о чём ему только что напомнили.
///
/// Тип общий для приложения и расширений: одна сторона ссылки собирает,
/// другая разбирает, и разъехаться они не могут.
enum DeepLink: Equatable {
    case today
    case capture(UUID)
    case reminder(UUID)
    case task(UUID)

    static let scheme = "ailife"

    // MARK: Сборка

    var url: URL? {
        switch self {
        case .today:
            return URL(string: "\(Self.scheme)://today")
        case .capture(let id):
            return URL(string: "\(Self.scheme)://capture/\(id.uuidString)")
        case .reminder(let id):
            return URL(string: "\(Self.scheme)://reminder/\(id.uuidString)")
        case .task(let id):
            return URL(string: "\(Self.scheme)://task/\(id.uuidString)")
        }
    }

    // MARK: Разбор

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host() else { return nil }

        // Идентификатор идёт первым компонентом пути: ailife://task/<uuid>
        let identifier = url.pathComponents
            .first { $0 != "/" }
            .flatMap(UUID.init(uuidString:))

        switch host {
        case "today":
            self = .today
        case "capture":
            guard let identifier else { return nil }
            self = .capture(identifier)
        case "reminder":
            guard let identifier else { return nil }
            self = .reminder(identifier)
        case "task":
            guard let identifier else { return nil }
            self = .task(identifier)
        default:
            return nil
        }
    }
}
