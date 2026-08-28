import Foundation
import SwiftData

/// Сырой захват: то, что пользователь сказал или прислал, до любого разбора.
///
/// Это источник истины и точка восстановления. Даже если разбор ошибся,
/// исходный текст и аудио остаются, поэтому запись всегда можно переиграть.
@Model
final class CaptureItem {

    /// Стабильный идентификатор, он же ключ строки в Supabase на Этапе 3.
    @Attribute(.unique) var id: UUID

    /// Распознанный или введённый текст.
    var text: String

    /// Финальный текст ещё не получен: показываем частичный результат.
    var isPartial: Bool

    var createdAt: Date
    var updatedAt: Date

    // MARK: Хранимые строки перечислений

    private var statusRaw: String
    private var sourceRaw: String
    private var engineRaw: String

    /// Код языка распознавания, например "ru-RU". Пусто, если язык не определялся.
    var languageCode: String?

    /// Уверенность распознавания речи, 0...1. Уверенность разбора смысла
    /// появится отдельным полем на Этапе 2.
    var recognitionConfidence: Double

    /// Длительность записи в секундах, 0 для текстовых захватов.
    var audioDuration: TimeInterval

    /// Имя файла записи внутри каталога Application Support.
    /// Храним имя, а не полный путь: путь к контейнеру меняется между запусками.
    var audioFileName: String?

    /// Текст ошибки последней неудачной обработки.
    var failureReason: String?

    /// Сколько раз пытались обработать. Нужен для отсечки бесконечных повторов.
    var processingAttempts: Int

    // MARK: Итог разбора

    /// Когда захват был разобран в последний раз.
    var parsedAt: Date?

    /// Какой движок дал итоговый разбор.
    private var parsingEngineRaw: String?

    /// Уверенность разбора смысла, 0...1. Отличается от уверенности
    /// распознавания речи: текст может быть распознан идеально,
    /// а смысл остаться неоднозначным.
    var parseConfidence: Double

    // MARK: Синхронизация

    private var syncStateRaw: String
    var remoteID: String?
    var lastSyncedAt: Date?

    // MARK: Порождённые сущности

    /// Один захват может породить несколько сущностей: «купил кофе за 300
    /// и напомни позвонить маме» это и расход, и напоминание.
    @Relationship(deleteRule: .cascade, inverse: \Note.source)
    var notes: [Note] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskItem.source)
    var tasks: [TaskItem] = []

    @Relationship(deleteRule: .cascade, inverse: \Reminder.source)
    var reminders: [Reminder] = []

    @Relationship(deleteRule: .cascade, inverse: \Expense.source)
    var expenses: [Expense] = []

    init(
        id: UUID = UUID(),
        text: String = "",
        isPartial: Bool = false,
        status: CaptureStatus = .pending,
        source: CaptureSource = .inApp,
        engine: SpeechEngineKind = .none,
        languageCode: String? = nil,
        recognitionConfidence: Double = 0,
        audioDuration: TimeInterval = 0,
        audioFileName: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.text = text
        self.isPartial = isPartial
        self.statusRaw = status.rawValue
        self.sourceRaw = source.rawValue
        self.engineRaw = engine.rawValue
        self.languageCode = languageCode
        self.recognitionConfidence = recognitionConfidence
        self.audioDuration = audioDuration
        self.audioFileName = audioFileName
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.processingAttempts = 0
        self.parseConfidence = 0
        self.syncStateRaw = SyncState.pendingUpload.rawValue
    }

    // MARK: Типизированный доступ

    var status: CaptureStatus {
        get { CaptureStatus(rawValue: statusRaw) ?? .pending }
        set {
            statusRaw = newValue.rawValue
            updatedAt = .now
        }
    }

    var source: CaptureSource {
        get { CaptureSource(rawValue: sourceRaw) ?? .inApp }
        set { sourceRaw = newValue.rawValue }
    }

    var engine: SpeechEngineKind {
        get { SpeechEngineKind(rawValue: engineRaw) ?? .none }
        set { engineRaw = newValue.rawValue }
    }

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .pendingUpload }
        set { syncStateRaw = newValue.rawValue }
    }

    var parsingEngine: ParsingEngine? {
        get { parsingEngineRaw.flatMap(ParsingEngine.init(rawValue:)) }
        set { parsingEngineRaw = newValue?.rawValue }
    }

    /// Порог уверенности, ниже которого разбор считается сомнительным.
    static let reviewConfidenceThreshold = 0.7

    /// Разбор дал неуверенный результат: запись стоит показать пользователю.
    var needsReview: Bool {
        parsedAt != nil && parseConfidence > 0 && parseConfidence < Self.reviewConfidenceThreshold
    }

    /// То же правило для выборок из базы.
    ///
    /// Одно место на всё приложение: раньше условие было переписано вручную
    /// в двух экранах и разъехалось бы при первом же изменении порога.
    /// Считать его перебором всей таблицы тем более нельзя: на двух тысячах
    /// записей это секундный фриз на каждую перерисовку.
    static var needsReviewPredicate: Predicate<CaptureItem> {
        let threshold = reviewConfidenceThreshold
        return #Predicate<CaptureItem> { capture in
            capture.parsedAt != nil
                && capture.parseConfidence > 0
                && capture.parseConfidence < threshold
        }
    }

    // MARK: Производные значения

    /// Есть ли у захвата хоть одна порождённая сущность.
    var hasDerivedItems: Bool {
        !notes.isEmpty || !tasks.isEmpty || !reminders.isEmpty || !expenses.isEmpty
    }

    var derivedItemsCount: Int {
        notes.count + tasks.count + reminders.count + expenses.count
    }

    /// Короткая выжимка для строки списка.
    var previewText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "capture.empty") }
        return trimmed
    }

    // MARK: Переходы состояния

    func markProcessing() {
        status = .processing
        processingAttempts += 1
        failureReason = nil
    }

    func markSynced(remoteID: String? = nil) {
        status = .synced
        failureReason = nil
        if let remoteID { self.remoteID = remoteID }
        lastSyncedAt = .now
        syncState = .synced
        updatedAt = .now
    }

    func markFailed(_ reason: String) {
        status = .failed
        failureReason = reason
        updatedAt = .now
    }
}
