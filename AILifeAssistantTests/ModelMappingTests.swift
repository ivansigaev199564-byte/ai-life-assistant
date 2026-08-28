import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Перевод в серверные представления и обратно.
///
/// Главное, что здесь проверяется, это правило разрешения конфликтов:
/// серверная копия принимается, только если она новее локальной.
/// Ошибка тут означает потерю правки, сделанной на телефоне.
@MainActor
final class ModelMappingTests: XCTestCase {

    /// Владелец записи: колонка на сервере обязательная, и раньше сюда
    /// уходил пустой идентификатор, из-за чего отправка не могла пройти.
    private static let owner = UUID()


    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: Захват

    func testCaptureRoundTrip() throws {
        let capture = CaptureItem(
            text: "купил кофе за 300",
            status: .synced,
            source: .actionButton,
            engine: .appleSpeech,
            languageCode: "ru-RU",
            recognitionConfidence: 0.93,
            audioDuration: 3.4
        )
        capture.parseConfidence = 0.88
        capture.parsingEngine = .cloud
        context.insert(capture)

        let dto = capture.dto(userID: Self.owner)

        XCTAssertEqual(dto.id, capture.id)
        XCTAssertEqual(dto.text, "купил кофе за 300")
        XCTAssertEqual(dto.source, "actionButton")
        XCTAssertEqual(dto.engine, "appleSpeech")
        XCTAssertEqual(dto.parsingEngine, "cloud")
        XCTAssertEqual(dto.parseConfidence, 0.88, accuracy: 0.001)

        let restored = CaptureItem.make(from: dto)
        XCTAssertEqual(restored.id, capture.id)
        XCTAssertEqual(restored.text, capture.text)
        XCTAssertEqual(restored.source, .actionButton)
        XCTAssertEqual(restored.parsingEngine, .cloud)
        XCTAssertEqual(restored.syncState, .synced)
    }

    /// Серверная копия новее: применяем.
    func testApplyAcceptsNewerServerCopy() throws {
        let capture = CaptureItem(text: "старый текст")
        capture.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(capture)

        var dto = capture.dto(userID: Self.owner)
        dto.text = "новый текст"
        dto.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(capture.apply(dto))
        XCTAssertEqual(capture.text, "новый текст")
        XCTAssertEqual(capture.syncState, .synced)
    }

    /// Локальная копия новее: серверную отбрасываем, иначе потеряем
    /// только что сделанную правку.
    func testApplyRejectsOlderServerCopy() throws {
        let capture = CaptureItem(text: "локальная правка")
        capture.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(capture)

        var dto = capture.dto(userID: Self.owner)
        dto.text = "устаревшее с сервера"
        dto.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertFalse(capture.apply(dto))
        XCTAssertEqual(capture.text, "локальная правка")
    }

    // MARK: Деньги

    /// Сумма едет строкой: перевод через число с плавающей точкой
    /// потерял бы копейки.
    func testExpenseAmountSurvivesRoundTrip() throws {
        let expense = Expense(
            amount: Decimal(string: "1234.56")!,
            currencyCode: "RUB",
            category: .food,
            details: "ужин"
        )
        context.insert(expense)

        let dto = expense.dto(userID: Self.owner)
        XCTAssertEqual(dto.amount, "1234.56")

        let restored = Expense.make(from: dto)
        XCTAssertEqual(restored.amount, Decimal(string: "1234.56"))
        XCTAssertEqual(restored.category, .food)
    }

    func testExpenseHandlesLargeAmount() throws {
        let expense = Expense(amount: Decimal(string: "9999999.99")!, currencyCode: "USD")
        context.insert(expense)

        let restored = Expense.make(from: expense.dto(userID: Self.owner))
        XCTAssertEqual(restored.amount, Decimal(string: "9999999.99"))
    }

    // MARK: Люди

    /// Псевдонимы объединяются, а не заменяются: на разных устройствах
    /// человек мог упоминаться в разных падежах, и обе формы полезны.
    func testPersonAliasesMerge() throws {
        let person = Person(name: "Миша", aliases: ["Мише"])
        person.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(person)

        var dto = person.dto(userID: Self.owner)
        dto.aliases = ["Мишу", "Михаил"]
        dto.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(person.apply(dto))
        XCTAssertTrue(person.aliases.contains("Мише"), "Локальная форма должна остаться")
        XCTAssertTrue(person.aliases.contains("Мишу"))
        XCTAssertTrue(person.aliases.contains("Михаил"))
    }

    /// Счётчик упоминаний берёт максимум: на другом устройстве человека
    /// могли упоминать чаще, и обнулять это нельзя.
    func testPersonMentionCountTakesMaximum() throws {
        let person = Person(name: "Оля")
        person.mentionCount = 10
        person.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(person)

        var dto = person.dto(userID: Self.owner)
        dto.mentionCount = 3
        dto.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        person.apply(dto)
        XCTAssertEqual(person.mentionCount, 10)
    }

    // MARK: Прочие сущности

    func testTaskRoundTripKeepsCompletion() throws {
        let task = TaskItem(title: "Купить билеты", priority: .high)
        task.toggleCompletion()
        context.insert(task)

        let restored = TaskItem.make(from: task.dto(userID: Self.owner))
        XCTAssertTrue(restored.isCompleted)
        XCTAssertNotNil(restored.completedAt)
        XCTAssertEqual(restored.priority, .high)
    }

    func testReminderRoundTripKeepsFireDate() throws {
        let fireDate = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = Reminder(title: "Позвонить", fireDate: fireDate)
        context.insert(reminder)

        let restored = Reminder.make(from: reminder.dto(userID: Self.owner))
        XCTAssertEqual(restored.fireDate.timeIntervalSince1970, fireDate.timeIntervalSince1970, accuracy: 1)
    }

    func testNoteRoundTripKeepsTags() throws {
        let note = Note(body: "мысль", tags: ["review", "идея"], needsReview: true)
        context.insert(note)

        let restored = Note.make(from: note.dto(userID: Self.owner))
        XCTAssertEqual(Set(restored.tags), Set(["review", "идея"]))
        XCTAssertTrue(restored.needsReview)
    }

    // MARK: Владелец

    /// Колонка user_id на сервере обязательная, а клиент отправлял пустое
    /// значение: ни одна запись не могла уехать в принципе.
    func testDTOCarriesOwner() {
        let capture = CaptureItem(text: "купил кофе за 300")
        XCTAssertEqual(capture.dto(userID: Self.owner).userId, Self.owner)

        let note = Note(title: "Идея", body: "проверить гипотезу")
        XCTAssertEqual(note.dto(userID: Self.owner).userId, Self.owner)

        let task = TaskItem(title: "Позвонить в банк")
        XCTAssertEqual(task.dto(userID: Self.owner).userId, Self.owner)

        let reminder = Reminder(title: "Витамины", fireDate: .now)
        XCTAssertEqual(reminder.dto(userID: Self.owner).userId, Self.owner)

        let expense = Expense(amount: 300)
        XCTAssertEqual(expense.dto(userID: Self.owner).userId, Self.owner)

        let person = Person(name: "Миша")
        XCTAssertEqual(person.dto(userID: Self.owner).userId, Self.owner)

        let project = Project(name: "Ремонт")
        XCTAssertEqual(project.dto(userID: Self.owner).userId, Self.owner)
    }
}
