import Foundation
import SwiftData

/// Перевод моделей SwiftData в серверные представления и обратно.
///
/// Правило применения одно на все типы: серверная копия принимается,
/// только если она новее локальной. Иначе синхронизация затирала бы
/// правку, сделанную на телефоне секунду назад, данными недельной давности.
///
/// Идентификатор пользователя приходит снаружи и подставляется в каждое
/// представление. Раньше он был жёстко записан пустым, а колонка на сервере
/// объявлена обязательной: отправка не могла пройти ни разу.

// MARK: Захват

extension CaptureItem {

    func dto(userID: UUID?) -> CaptureDTO {
        CaptureDTO(
            id: id,
            userId: userID,
            text: text,
            source: source.rawValue,
            status: status.rawValue,
            engine: engine.rawValue,
            languageCode: languageCode,
            recognitionConfidence: recognitionConfidence,
            parseConfidence: parseConfidence,
            parsingEngine: parsingEngine?.rawValue,
            audioDuration: audioDuration,
            createdAt: createdAt,
            updatedAt: updatedAt,
            parsedAt: parsedAt,
            deletedAt: nil,
            version: 1
        )
    }

    /// Применяет серверную копию. Возвращает false, если локальная новее.
    @discardableResult
    func apply(_ dto: CaptureDTO) -> Bool {
        guard dto.updatedAt > updatedAt else { return false }

        text = dto.text
        source = CaptureSource(rawValue: dto.source) ?? source
        status = CaptureStatus(rawValue: dto.status) ?? status
        engine = SpeechEngineKind(rawValue: dto.engine) ?? engine
        languageCode = dto.languageCode
        recognitionConfidence = dto.recognitionConfidence
        parseConfidence = dto.parseConfidence
        parsingEngine = dto.parsingEngine.flatMap(ParsingEngine.init(rawValue:))
        audioDuration = dto.audioDuration
        parsedAt = dto.parsedAt
        updatedAt = dto.updatedAt
        syncState = .synced
        lastSyncedAt = .now
        return true
    }

    static func make(from dto: CaptureDTO) -> CaptureItem {
        let capture = CaptureItem(
            id: dto.id,
            text: dto.text,
            status: CaptureStatus(rawValue: dto.status) ?? .pending,
            source: CaptureSource(rawValue: dto.source) ?? .inApp,
            engine: SpeechEngineKind(rawValue: dto.engine) ?? .none,
            languageCode: dto.languageCode,
            recognitionConfidence: dto.recognitionConfidence,
            audioDuration: dto.audioDuration,
            createdAt: dto.createdAt
        )
        capture.parseConfidence = dto.parseConfidence
        capture.parsingEngine = dto.parsingEngine.flatMap(ParsingEngine.init(rawValue:))
        capture.parsedAt = dto.parsedAt
        capture.updatedAt = dto.updatedAt
        capture.syncState = .synced
        capture.lastSyncedAt = .now
        return capture
    }
}

// MARK: Заметка

extension Note {

    func dto(userID: UUID?) -> NoteDTO {
        NoteDTO(
            id: id,
            userId: userID,
            captureId: source?.id,
            parsedItemId: parsedItemID,
            title: title,
            body: body,
            tags: tags,
            confidence: confidence,
            needsReview: needsReview,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: nil,
            version: 1
        )
    }

    @discardableResult
    func apply(_ dto: NoteDTO) -> Bool {
        guard dto.updatedAt > updatedAt else { return false }

        title = dto.title
        body = dto.body
        tags = dto.tags
        confidence = dto.confidence
        needsReview = dto.needsReview
        isArchived = dto.isArchived
        parsedItemID = dto.parsedItemId
        updatedAt = dto.updatedAt
        syncState = .synced
        lastSyncedAt = .now
        return true
    }

    static func make(from dto: NoteDTO) -> Note {
        let note = Note(
            id: dto.id,
            title: dto.title,
            body: dto.body,
            tags: dto.tags,
            confidence: dto.confidence,
            needsReview: dto.needsReview,
            createdAt: dto.createdAt
        )
        note.parsedItemID = dto.parsedItemId
        note.isArchived = dto.isArchived
        note.updatedAt = dto.updatedAt
        note.syncState = .synced
        return note
    }
}

// MARK: Задача

extension TaskItem {

    func dto(userID: UUID?) -> TaskDTO {
        TaskDTO(
            id: id,
            userId: userID,
            captureId: source?.id,
            parsedItemId: parsedItemID,
            title: title,
            details: details,
            dueDate: dueDate,
            priority: priority.rawValue,
            isCompleted: isCompleted,
            completedAt: completedAt,
            externalReminderId: externalReminderID,
            confidence: confidence,
            needsReview: needsReview,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: nil,
            version: 1
        )
    }

    @discardableResult
    func apply(_ dto: TaskDTO) -> Bool {
        guard dto.updatedAt > updatedAt else { return false }

        title = dto.title
        details = dto.details
        dueDate = dto.dueDate
        priority = Priority(rawValue: dto.priority) ?? priority
        isCompleted = dto.isCompleted
        completedAt = dto.completedAt
        externalReminderID = dto.externalReminderId
        confidence = dto.confidence
        needsReview = dto.needsReview
        parsedItemID = dto.parsedItemId
        updatedAt = dto.updatedAt
        syncState = .synced
        lastSyncedAt = .now
        return true
    }

    static func make(from dto: TaskDTO) -> TaskItem {
        let task = TaskItem(
            id: dto.id,
            title: dto.title,
            details: dto.details,
            dueDate: dto.dueDate,
            priority: Priority(rawValue: dto.priority) ?? .none,
            confidence: dto.confidence,
            needsReview: dto.needsReview,
            createdAt: dto.createdAt
        )
        task.parsedItemID = dto.parsedItemId
        task.isCompleted = dto.isCompleted
        task.completedAt = dto.completedAt
        task.externalReminderID = dto.externalReminderId
        task.updatedAt = dto.updatedAt
        task.syncState = .synced
        return task
    }
}

// MARK: Напоминание

extension Reminder {

    func dto(userID: UUID?) -> ReminderDTO {
        ReminderDTO(
            id: id,
            userId: userID,
            captureId: source?.id,
            parsedItemId: parsedItemID,
            title: title,
            details: details,
            fireDate: fireDate,
            recurrenceRule: recurrenceRule,
            priority: priority.rawValue,
            isCompleted: isCompleted,
            completedAt: completedAt,
            externalIdentifier: externalIdentifier,
            confidence: confidence,
            needsReview: needsReview,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: nil,
            version: 1
        )
    }

    @discardableResult
    func apply(_ dto: ReminderDTO) -> Bool {
        guard dto.updatedAt > updatedAt else { return false }

        title = dto.title
        details = dto.details
        fireDate = dto.fireDate
        recurrenceRule = dto.recurrenceRule
        priority = Priority(rawValue: dto.priority) ?? priority
        isCompleted = dto.isCompleted
        completedAt = dto.completedAt
        externalIdentifier = dto.externalIdentifier
        confidence = dto.confidence
        needsReview = dto.needsReview
        parsedItemID = dto.parsedItemId
        updatedAt = dto.updatedAt
        syncState = .synced
        lastSyncedAt = .now
        return true
    }

    static func make(from dto: ReminderDTO) -> Reminder {
        let reminder = Reminder(
            id: dto.id,
            title: dto.title,
            details: dto.details,
            fireDate: dto.fireDate,
            recurrenceRule: dto.recurrenceRule,
            priority: Priority(rawValue: dto.priority) ?? .none,
            confidence: dto.confidence,
            needsReview: dto.needsReview,
            createdAt: dto.createdAt
        )
        reminder.parsedItemID = dto.parsedItemId
        reminder.isCompleted = dto.isCompleted
        reminder.completedAt = dto.completedAt
        reminder.externalIdentifier = dto.externalIdentifier
        reminder.updatedAt = dto.updatedAt
        reminder.syncState = .synced
        return reminder
    }
}

// MARK: Расход

extension Expense {

    func dto(userID: UUID?) -> ExpenseDTO {
        ExpenseDTO(
            id: id,
            userId: userID,
            captureId: source?.id,
            parsedItemId: parsedItemID,
            // Сумма уезжает строкой: перевод через число с плавающей
            // точкой потерял бы копейки на длинной дистанции.
            amount: NSDecimalNumber(decimal: amount).stringValue,
            currencyCode: currencyCode,
            category: category.rawValue,
            details: details,
            merchant: merchant,
            spentAt: spentAt,
            confidence: confidence,
            needsReview: needsReview,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: nil,
            version: 1
        )
    }

    @discardableResult
    func apply(_ dto: ExpenseDTO) -> Bool {
        guard dto.updatedAt > updatedAt else { return false }

        if let parsed = Decimal(string: dto.amount) {
            amount = parsed
        }
        currencyCode = dto.currencyCode
        category = ExpenseCategory(rawValue: dto.category) ?? category
        details = dto.details
        merchant = dto.merchant
        spentAt = dto.spentAt
        confidence = dto.confidence
        needsReview = dto.needsReview
        parsedItemID = dto.parsedItemId
        updatedAt = dto.updatedAt
        syncState = .synced
        lastSyncedAt = .now
        return true
    }

    static func make(from dto: ExpenseDTO) -> Expense {
        let expense = Expense(
            id: dto.id,
            amount: Decimal(string: dto.amount) ?? 0,
            currencyCode: dto.currencyCode,
            category: ExpenseCategory(rawValue: dto.category) ?? .other,
            details: dto.details,
            merchant: dto.merchant,
            spentAt: dto.spentAt,
            confidence: dto.confidence,
            needsReview: dto.needsReview,
            createdAt: dto.createdAt
        )
        expense.parsedItemID = dto.parsedItemId
        expense.updatedAt = dto.updatedAt
        expense.syncState = .synced
        return expense
    }
}

// MARK: Человек и проект

extension Person {

    func dto(userID: UUID?) -> PersonDTO {
        PersonDTO(
            id: id,
            userId: userID,
            name: name,
            normalizedName: normalizedName,
            aliases: aliases,
            contactIdentifier: contactIdentifier,
            mentionCount: mentionCount,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: nil,
            version: 1
        )
    }

    @discardableResult
    func apply(_ dto: PersonDTO) -> Bool {
        guard dto.updatedAt > updatedAt else { return false }

        name = dto.name
        normalizedName = dto.normalizedName
        // Псевдонимы объединяются, а не заменяются: на разных устройствах
        // человек мог упоминаться в разных падежах, и обе формы полезны.
        aliases = Array(Set(aliases + dto.aliases)).sorted()
        contactIdentifier = dto.contactIdentifier
        mentionCount = max(mentionCount, dto.mentionCount)
        updatedAt = dto.updatedAt
        syncState = .synced
        return true
    }

    static func make(from dto: PersonDTO) -> Person {
        let person = Person(
            id: dto.id,
            name: dto.name,
            aliases: dto.aliases,
            contactIdentifier: dto.contactIdentifier,
            createdAt: dto.createdAt
        )
        person.mentionCount = dto.mentionCount
        person.updatedAt = dto.updatedAt
        person.syncState = .synced
        return person
    }
}

extension Project {

    func dto(userID: UUID?) -> ProjectDTO {
        ProjectDTO(
            id: id,
            userId: userID,
            name: name,
            normalizedName: normalizedName,
            aliases: aliases,
            details: details,
            colorHex: colorHex,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: nil,
            version: 1
        )
    }

    @discardableResult
    func apply(_ dto: ProjectDTO) -> Bool {
        guard dto.updatedAt > updatedAt else { return false }

        name = dto.name
        normalizedName = dto.normalizedName
        aliases = Array(Set(aliases + dto.aliases)).sorted()
        details = dto.details
        colorHex = dto.colorHex
        isArchived = dto.isArchived
        updatedAt = dto.updatedAt
        syncState = .synced
        return true
    }

    static func make(from dto: ProjectDTO) -> Project {
        let project = Project(
            id: dto.id,
            name: dto.name,
            aliases: dto.aliases,
            details: dto.details,
            colorHex: dto.colorHex,
            createdAt: dto.createdAt
        )
        project.isArchived = dto.isArchived
        project.updatedAt = dto.updatedAt
        project.syncState = .synced
        return project
    }
}
