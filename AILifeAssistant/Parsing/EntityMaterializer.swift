import Foundation
import SwiftData

/// Превращает результат разбора в записи SwiftData.
///
/// Работает идемпотентно: повторный вызов с уточнённым разбором обновляет
/// уже созданные сущности, а не плодит копии. Это условие всей схемы
/// с каскадом движков, где одна фраза разбирается дважды или трижды.
@MainActor
struct EntityMaterializer {

    struct Result: Equatable, Sendable {
        var created: Int = 0
        var updated: Int = 0
        /// Сколько элементов ушло в заметку на проверку из-за низкой уверенности.
        var flaggedForReview: Int = 0
        /// Сколько элементов отброшено как бессмысленные.
        var discarded: Int = 0

        var total: Int { created + updated + flaggedForReview }
    }

    /// Порог уверенности из ТЗ: ниже него сущность не создаётся, а сказанное
    /// сохраняется заметкой с пометкой на проверку. Неверно созданная задача
    /// обходится пользователю дороже, чем лишняя заметка.
    static let confidenceThreshold = 0.7

    /// Метка заметок, требующих проверки.
    static let reviewTag = "review"

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: Точка входа

    @discardableResult
    func materialize(_ intent: ParsedIntent, for capture: CaptureItem) -> Result {
        var result = Result()

        let people = resolvePeople(intent.people)
        let projects = resolveProjects(intent.projects)

        for item in intent.items {
            guard item.isValid else {
                result.discarded += 1
                continue
            }

            if item.confidence < Self.confidenceThreshold {
                createReviewNote(from: item, capture: capture, people: people, projects: projects)
                result.flaggedForReview += 1
                continue
            }

            let existed = apply(item, capture: capture, people: people, projects: projects)
            if existed {
                result.updated += 1
            } else {
                result.created += 1
            }
        }

        capture.parsedAt = .now
        capture.parsingEngine = intent.engine
        capture.parseConfidence = intent.confidence
        capture.status = result.total > 0 ? .synced : .failed
        if result.total == 0 {
            capture.failureReason = "Разбор не дал ни одной записи"
        }

        save()
        return result
    }

    // MARK: Создание и обновление

    /// Возвращает true, если сущность уже существовала и была обновлена.
    private func apply(
        _ item: ParsedItem,
        capture: CaptureItem,
        people: [Person],
        projects: [Project]
    ) -> Bool {
        // Людей, названных в самом элементе, отбираем из общего списка фразы.
        let itemPeople = people.filter { person in
            item.people.isEmpty || item.people.contains { person.matches($0) }
        }

        switch item.kind {
        case .note:
            if let existing = capture.notes.first(where: { $0.parsedItemID == item.id }) {
                // Поправленное человеком не перезаписываем: разбор здесь
                // заведомо хуже, он уже один раз ошибся.
                guard !existing.isUserEdited else { return true }
                existing.title = item.title
                existing.body = item.details.isEmpty ? item.sourceText : item.details
                existing.confidence = item.confidence
                existing.updatedAt = .now
                existing.syncState = .pendingUpload
                return true
            }
            let note = Note(
                title: item.title,
                body: item.details.isEmpty ? item.sourceText : item.details,
                confidence: item.confidence,
                source: capture
            )
            note.parsedItemID = item.id
            note.people = itemPeople
            note.projects = projects
            modelContext.insert(note)
            return false

        case .task:
            if let existing = capture.tasks.first(where: { $0.parsedItemID == item.id }) {
                guard !existing.isUserEdited else { return true }
                existing.title = item.title
                existing.details = item.details
                existing.dueDate = item.dueDate
                existing.priority = item.priority
                existing.confidence = item.confidence
                existing.updatedAt = .now
                existing.syncState = .pendingUpload
                return true
            }
            let task = TaskItem(
                title: item.title,
                details: item.details,
                dueDate: item.dueDate,
                priority: item.priority,
                confidence: item.confidence,
                source: capture
            )
            task.parsedItemID = item.id
            task.people = itemPeople
            task.projects = projects
            modelContext.insert(task)
            return false

        case .reminder:
            guard let fireDate = item.dueDate else { return false }

            if let existing = capture.reminders.first(where: { $0.parsedItemID == item.id }) {
                guard !existing.isUserEdited else { return true }
                existing.title = item.title
                existing.details = item.details
                existing.fireDate = fireDate
                existing.recurrenceRule = item.recurrenceRule
                existing.priority = item.priority
                existing.confidence = item.confidence
                existing.updatedAt = .now
                existing.syncState = .pendingUpload
                return true
            }
            let reminder = Reminder(
                title: item.title,
                details: item.details,
                fireDate: fireDate,
                // Без этого поля «каждый день в полдевятого» приходило
                // ровно один раз: правило оставалось строкой в описании.
                recurrenceRule: item.recurrenceRule,
                priority: item.priority,
                confidence: item.confidence,
                source: capture
            )
            reminder.parsedItemID = item.id
            reminder.people = itemPeople
            reminder.projects = projects
            modelContext.insert(reminder)
            return false

        case .expense:
            guard let amount = item.amount else { return false }

            if let existing = capture.expenses.first(where: { $0.parsedItemID == item.id }) {
                guard !existing.isUserEdited else { return true }
                existing.amount = amount
                existing.currencyCode = item.currencyCode ?? existing.currencyCode
                existing.category = item.category ?? existing.category
                existing.details = item.title.isEmpty ? item.details : item.title
                existing.merchant = item.merchant
                existing.confidence = item.confidence
                existing.updatedAt = .now
                existing.syncState = .pendingUpload
                return true
            }
            let expense = Expense(
                amount: amount,
                currencyCode: item.currencyCode ?? Locale.current.currency?.identifier ?? "RUB",
                category: item.category ?? .other,
                details: item.title.isEmpty ? item.details : item.title,
                merchant: item.merchant,
                spentAt: item.dueDate ?? capture.createdAt,
                confidence: item.confidence,
                source: capture
            )
            expense.parsedItemID = item.id
            expense.people = itemPeople
            expense.projects = projects
            modelContext.insert(expense)
            return false
        }
    }

    /// Неуверенный разбор сохраняем заметкой с пометкой: сказанное
    /// не теряется, но и неверная задача не появляется.
    private func createReviewNote(
        from item: ParsedItem,
        capture: CaptureItem,
        people: [Person],
        projects: [Project]
    ) {
        if let existing = capture.notes.first(where: { $0.parsedItemID == item.id }) {
            existing.body = item.sourceText.isEmpty ? item.title : item.sourceText
            existing.needsReview = true
            existing.updatedAt = .now
            return
        }

        let note = Note(
            title: item.title,
            body: item.sourceText.isEmpty ? item.details : item.sourceText,
            tags: [Self.reviewTag],
            confidence: item.confidence,
            needsReview: true,
            source: capture
        )
        note.parsedItemID = item.id
        note.people = people
        note.projects = projects
        modelContext.insert(note)
    }

    // MARK: Люди и проекты

    /// Находит существующих людей или заводит новых.
    ///
    /// Сопоставление идёт через Person.matches, который знает про падежи
    /// и синонимы: «Мише» находит «Мишу», а не создаёт вторую карточку.
    private func resolvePeople(_ names: [String]) -> [Person] {
        guard !names.isEmpty else { return [] }

        let existing = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        var result: [Person] = []

        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { continue }

            if let match = existing.first(where: { $0.matches(trimmed) }) {
                match.registerMention()
                // Новая форма имени пополняет список синонимов,
                // чтобы в следующий раз совпадение нашлось быстрее.
                if !match.aliases.contains(trimmed), match.name != trimmed {
                    match.aliases.append(trimmed)
                }
                result.append(match)
                continue
            }

            if let alreadyAdded = result.first(where: { $0.matches(trimmed) }) {
                _ = alreadyAdded
                continue
            }

            let person = Person(name: trimmed)
            person.registerMention()
            modelContext.insert(person)
            result.append(person)
        }
        return result
    }

    /// Проекты только ищет: придумывать новые проекты по одной фразе
    /// слишком самонадеянно, это делается пользователем осознанно.
    private func resolveProjects(_ names: [String]) -> [Project] {
        guard !names.isEmpty else { return [] }

        let existing = (try? modelContext.fetch(FetchDescriptor<Project>())) ?? []
        return names.compactMap { name in
            existing.first { $0.matches(name) }
        }
    }

    // MARK: Сохранение

    private func save() {
        do {
            try modelContext.save()
        } catch {
            Log.data.error("Не удалось сохранить результат разбора: \(error.localizedDescription)")
        }
    }
}
