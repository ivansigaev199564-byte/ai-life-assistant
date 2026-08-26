import Foundation

/// Стадия обработки сырого захвата.
///
/// Значения хранятся в SwiftData строками: с `String` корректно работает
/// `#Predicate`, а миграции не ломаются при добавлении новых случаев.
enum CaptureStatus: String, Codable, CaseIterable, Sendable {
    /// Записано локально, разбор ещё не начинался.
    case pending
    /// Идёт локальный или облачный разбор.
    case processing
    /// Разобрано, сущности созданы, отправлено в бэкенд.
    case synced
    /// Разбор или отправка сорвались, есть текст ошибки.
    case failed

    var isTerminal: Bool { self == .synced || self == .failed }
}

/// Откуда пришёл захват. Нужен для аналитики и для разной обработки:
/// голос требует распознавания, текст из Share Extension нет.
enum CaptureSource: String, Codable, CaseIterable, Sendable {
    case actionButton
    case controlCenter
    case widget
    case siri
    case inApp
    case shareExtension
    case manualText
}

/// Какой движок распознал речь. Хранится в захвате, чтобы можно было
/// сравнивать качество и объяснять пользователю расхождения.
enum SpeechEngineKind: String, Codable, CaseIterable, Sendable {
    /// SFSpeechRecognizer, доступен на всём диапазоне iOS 18+.
    case appleSpeech
    /// SpeechAnalyzer, iOS 26 и новее.
    case appleModernSpeech
    /// WhisperKit, локальная модель с автоопределением языка.
    case whisperKit
    /// Текст введён руками, распознавание не применялось.
    case none

    var displayName: String {
        switch self {
        case .appleSpeech: return String(localized: "engine.apple.speech")
        case .appleModernSpeech: return String(localized: "engine.apple.modern")
        case .whisperKit: return String(localized: "engine.whisperkit")
        case .none: return String(localized: "engine.none")
        }
    }
}

/// Приоритет задачи или напоминания. Совпадает по смыслу с приоритетами
/// в Apple Reminders, чтобы Этап 4 не требовал перекодировки.
enum Priority: String, Codable, CaseIterable, Sendable {
    case none
    case low
    case medium
    case high

    /// Значение, которое понимает EventKit (0 нет, 9 низкий, 5 средний, 1 высокий).
    var ekPriority: Int {
        switch self {
        case .none: return 0
        case .low: return 9
        case .medium: return 5
        case .high: return 1
        }
    }

    var displayName: String {
        switch self {
        case .none: return String(localized: "priority.none")
        case .low: return String(localized: "priority.low")
        case .medium: return String(localized: "priority.medium")
        case .high: return String(localized: "priority.high")
        }
    }
}

/// Категория расхода. Набор закрытый, чтобы облачный разбор возвращал
/// предсказуемые значения, а не свободный текст.
enum ExpenseCategory: String, Codable, CaseIterable, Sendable {
    case food
    case transport
    case housing
    case health
    case entertainment
    case shopping
    case education
    case travel
    case services
    case other

    var displayName: String {
        String(localized: String.LocalizationValue("expense.category." + rawValue))
    }

    var symbolName: String {
        switch self {
        case .food: return "fork.knife"
        case .transport: return "car.fill"
        case .housing: return "house.fill"
        case .health: return "cross.case.fill"
        case .entertainment: return "film.fill"
        case .shopping: return "bag.fill"
        case .education: return "book.fill"
        case .travel: return "airplane"
        case .services: return "wrench.and.screwdriver.fill"
        case .other: return "square.grid.2x2"
        }
    }
}

/// Состояние синхронизации с бэкендом. Заполняется на Этапе 3,
/// но живёт в моделях с самого начала, чтобы не делать миграцию схемы.
enum SyncState: String, Codable, CaseIterable, Sendable {
    /// Есть локальные изменения, которых нет на сервере.
    case pendingUpload
    /// Локальная копия совпадает с серверной.
    case synced
    /// Отправка сорвалась, нужен повтор.
    case failed
}
