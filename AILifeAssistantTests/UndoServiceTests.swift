import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Баннер отмены. Пять секунд, за которые человек должен успеть передумать,
/// и ни одного повода отменить не то, на что он смотрит.
@MainActor
final class UndoServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var undo: UndoService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        undo = UndoService(modelContext: context)
    }

    override func tearDownWithError() throws {
        undo = nil
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    func testShowsRawTextUntilParsingFinishes() throws {
        let capture = CaptureItem(text: "купил кофе за 300")
        context.insert(capture)
        try context.save()

        undo.register(captureCreated: capture)

        XCTAssertEqual(undo.pending?.message, "купил кофе за 300")
    }

    /// Разбор уточняет уже показанный баннер, а не создаёт новый.
    func testUpdatesSummaryOfSameCapture() throws {
        let capture = CaptureItem(text: "купил кофе за 300")
        context.insert(capture)
        try context.save()

        undo.register(captureCreated: capture)
        let bannerID = try XCTUnwrap(undo.pending?.id)

        context.insert(Expense(amount: 300, currencyCode: "RUB", category: .food, source: capture))
        try context.save()

        undo.updateSummary(for: capture)

        XCTAssertEqual(undo.pending?.id, bannerID, "Баннер тот же самый, поменялся только текст")
        XCTAssertTrue(
            undo.pending?.message.contains("Создано") == true,
            "После разбора баннер показывает результат, получено: \(undo.pending?.message ?? "nil")"
        )
    }

    /// Главный сценарий, ради которого всё и переделано: разбор записи,
    /// которую пользователь не создавал прямо сейчас, не должен всплывать
    /// предложением её удалить. Именно это происходило при запуске
    /// приложения с недоразобранными записями со вчера.
    func testDoesNotCreateBannerOutOfNowhere() throws {
        let capture = CaptureItem(text: "вчерашняя запись")
        context.insert(capture)
        try context.save()

        undo.updateSummary(for: capture)

        XCTAssertNil(undo.pending, "Баннера не было, появиться ему неоткуда")
    }

    /// Две быстрые диктовки подряд: разбор первой не должен подменять
    /// баннер второй, иначе «Отменить» удалит не ту запись.
    func testDoesNotHijackBannerOfAnotherCapture() throws {
        let first = CaptureItem(text: "первая запись")
        let second = CaptureItem(text: "вторая запись")
        context.insert(first)
        context.insert(second)
        try context.save()

        undo.register(captureCreated: second)
        undo.updateSummary(for: first)

        XCTAssertEqual(undo.pending?.message, "вторая запись")
        guard case .captureCreated(let id)? = undo.pending?.kind else {
            return XCTFail("Ожидалась отмена создания записи")
        }
        XCTAssertEqual(id, second.id)
    }

    func testUndoDeletesCapture() throws {
        let capture = CaptureItem(text: "случайная запись")
        context.insert(capture)
        try context.save()

        var undoneIDs: [UUID] = []
        undo.onUndone = { action in
            if case .captureCreated(let id) = action.kind { undoneIDs.append(id) }
        }

        undo.register(captureCreated: capture)
        undo.undo()

        XCTAssertTrue(try context.fetch(FetchDescriptor<CaptureItem>()).isEmpty)
        XCTAssertEqual(undoneIDs, [capture.id], "Синхронизация должна узнать об удалении")
        XCTAssertNil(undo.pending)
    }
}
