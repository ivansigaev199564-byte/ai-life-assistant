import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Голосовое исправление в том виде, в каком оно происходит на устройстве.
///
/// Отдельно от `CorrectionTests`: там применение вызывается напрямую на базе,
/// где лежит только запись-цель. В жизни всё иначе, фраза-исправление уже
/// сохранена и является самой свежей записью, и ровно на этом приложение
/// раньше спотыкалось: «отмени последнюю запись» удаляло само себя.
@MainActor
final class CorrectionFlowTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var queue: ProcessingQueue!
    private var outcomes: [CorrectionApplier.Outcome] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        outcomes = []

        queue = ProcessingQueue(modelContext: context, pipeline: ParsingPipeline())
        queue.onCorrectionApplied = { [weak self] outcome in
            self?.outcomes.append(outcome)
        }
    }

    override func tearDownWithError() throws {
        queue = nil
        context = nil
        container = nil
        outcomes = []
        try super.tearDownWithError()
    }

    // MARK: Отмена

    func testCancellationRemovesPreviousCaptureNotItself() async throws {
        let expense = CaptureItem(
            text: "купил кофе за 300 рублей",
            source: .inApp,
            createdAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
        context.insert(expense)
        try context.save()

        await queue.processPending()
        XCTAssertFalse(expense.expenses.isEmpty, "Разбор должен был создать расход")

        let cancellation = CaptureItem(
            text: "отмени последнюю запись",
            source: .inApp,
            createdAt: Date(timeIntervalSince1970: 1_787_000_030)
        )
        context.insert(cancellation)
        try context.save()

        await queue.processPending()

        let remaining = try context.fetch(FetchDescriptor<CaptureItem>())
        XCTAssertTrue(
            remaining.isEmpty,
            "Уйти должны обе записи: и трата, и сама фраза отмены, осталось \(remaining.map(\.text))"
        )

        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(outcome.action, .captureRemoved)
        XCTAssertEqual(outcome.removed?.text, "купил кофе за 300 рублей", "Удалена должна быть трата")
    }

    /// Фраза-исправление без цели это обычная запись, а не команда в пустоту.
    func testCorrectionWithoutTargetStaysAsCapture() async throws {
        let lonely = CaptureItem(text: "отмени последнюю запись", source: .inApp)
        context.insert(lonely)
        try context.save()

        await queue.processPending()

        let remaining = try context.fetch(FetchDescriptor<CaptureItem>())
        XCTAssertEqual(remaining.count, 1, "Отменять нечего, запись должна остаться")
        XCTAssertTrue(outcomes.isEmpty)
    }

    // MARK: Правка суммы

    func testAmountCorrectionEditsPreviousCapture() async throws {
        let original = CaptureItem(
            text: "купил кофе за 46 рублей",
            source: .inApp,
            createdAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
        context.insert(original)
        try context.save()
        await queue.processPending()

        let correction = CaptureItem(
            text: "не 46, а 64 рубля",
            source: .inApp,
            createdAt: Date(timeIntervalSince1970: 1_787_000_020)
        )
        context.insert(correction)
        try context.save()
        await queue.processPending()

        let remaining = try context.fetch(FetchDescriptor<CaptureItem>())
        XCTAssertEqual(remaining.count, 1, "Вторая запись не создаётся, правится первая")

        let expense = try XCTUnwrap(remaining.first?.expenses.first)
        XCTAssertEqual(expense.amount, 64)
    }

    // MARK: Откат

    func testUndoRestoresCaptureRemovedByVoice() async throws {
        let expense = CaptureItem(
            text: "потратил 4500 в Ленте",
            source: .inApp,
            createdAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
        context.insert(expense)
        try context.save()
        await queue.processPending()

        let cancellation = CaptureItem(
            text: "отмени последнюю запись",
            source: .inApp,
            createdAt: Date(timeIntervalSince1970: 1_787_000_040)
        )
        context.insert(cancellation)
        try context.save()
        await queue.processPending()

        let outcome = try XCTUnwrap(outcomes.first)
        let applier = CorrectionApplier(modelContext: context)

        XCTAssertEqual(applier.revert(outcome), .restored(outcome.removed?.id ?? UUID()))

        let restored = try context.fetch(FetchDescriptor<CaptureItem>())
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.text, "потратил 4500 в Ленте")
        XCTAssertEqual(restored.first?.status, .pending, "Вернувшаяся запись ждёт повторного разбора")
    }

    func testUndoReturnsPreviousAmount() async throws {
        let original = CaptureItem(
            text: "купил кофе за 46 рублей",
            source: .inApp,
            createdAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
        context.insert(original)
        try context.save()
        await queue.processPending()

        let correction = CaptureItem(
            text: "не 46, а 64 рубля",
            source: .inApp,
            createdAt: Date(timeIntervalSince1970: 1_787_000_020)
        )
        context.insert(correction)
        try context.save()
        await queue.processPending()

        let outcome = try XCTUnwrap(outcomes.first)
        let applier = CorrectionApplier(modelContext: context)
        XCTAssertEqual(applier.revert(outcome), .reverted)

        let expense = try XCTUnwrap(
            context.fetch(FetchDescriptor<CaptureItem>()).first?.expenses.first
        )
        XCTAssertEqual(expense.amount, 46, "Сумма должна вернуться к прежней")
    }
}
