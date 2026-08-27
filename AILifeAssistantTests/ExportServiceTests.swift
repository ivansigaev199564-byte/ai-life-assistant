import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Выгрузка данных.
///
/// Проверяется не «файл создался», а то, ради чего выгрузка существует:
/// данные должны пережить перенос без потерь. Особенно деньги: копейка,
/// потерянная при округлении, обесценивает весь файл.
@MainActor
final class ExportServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: ExportService!
    private var createdFiles: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try Persistence.makeContainer(inMemory: true)
        context = container.mainContext
        service = ExportService(modelContext: context)
    }

    override func tearDownWithError() throws {
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
        createdFiles = []
        service = nil
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    private func export(_ format: ExportService.Format) throws -> URL {
        let url = try service.export(format)
        createdFiles.append(url)
        return url
    }

    // MARK: JSON

    func testJSONContainsAllEntityTypes() throws {
        let capture = CaptureItem(text: "купил кофе за 300 и напомни позвонить маме")
        context.insert(capture)
        context.insert(Note(body: "идея", source: capture))
        context.insert(TaskItem(title: "заказать воду", source: capture))
        context.insert(Reminder(title: "позвонить маме", fireDate: .now.addingTimeInterval(3600), source: capture))
        context.insert(Expense(amount: 300, category: .food, source: capture))
        context.insert(Person(name: "Мама"))
        context.insert(Project(name: "Дом"))
        try context.save()

        let url = try export(.json)
        let json = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: url)
        ) as? [String: Any]

        let root = try XCTUnwrap(json)
        XCTAssertEqual((root["captures"] as? [Any])?.count, 1)
        XCTAssertEqual((root["notes"] as? [Any])?.count, 1)
        XCTAssertEqual((root["tasks"] as? [Any])?.count, 1)
        XCTAssertEqual((root["reminders"] as? [Any])?.count, 1)
        XCTAssertEqual((root["expenses"] as? [Any])?.count, 1)
        XCTAssertEqual((root["people"] as? [Any])?.count, 1)
        XCTAssertEqual((root["projects"] as? [Any])?.count, 1)
        XCTAssertNotNil(root["exportedAt"])
    }

    /// Сумма едет строкой: число с плавающей точкой в JSON округляется,
    /// и копейки теряются ровно там, где терять их нельзя.
    func testJSONKeepsExactAmount() throws {
        context.insert(Expense(amount: Decimal(string: "1234.56")!, currencyCode: "RUB"))
        try context.save()

        let url = try export(.json)
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        let expenses = try XCTUnwrap((json?["expenses"] as? [[String: Any]])?.first)

        XCTAssertEqual(expenses["amount"] as? String, "1234.56")
    }

    /// Связь записи с исходным захватом должна пережить перенос,
    /// иначе в файле окажется набор сущностей без истории.
    func testJSONKeepsLinkToCapture() throws {
        let capture = CaptureItem(text: "напомни позвонить")
        context.insert(capture)
        context.insert(Reminder(title: "позвонить", fireDate: .now.addingTimeInterval(600), source: capture))
        try context.save()

        let url = try export(.json)
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        let reminder = try XCTUnwrap((json?["reminders"] as? [[String: Any]])?.first)

        XCTAssertEqual(reminder["captureId"] as? String, capture.id.uuidString)
    }

    // MARK: CSV

    func testCSVHasHeaderAndRows() throws {
        context.insert(Expense(amount: 300, currencyCode: "RUB", category: .food, details: "кофе"))
        context.insert(Expense(amount: 500, currencyCode: "RUB", category: .transport, details: "такси"))
        try context.save()

        let url = try export(.csv)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 3, "Заголовок и две строки")
        XCTAssertTrue(lines[1].contains("300"))
        XCTAssertTrue(lines[2].contains("500"))
    }

    /// Описание траты вполне может содержать запятую, и без экранирования
    /// файл разъедется на лишние колонки.
    func testCSVEscapesCommas() throws {
        context.insert(Expense(amount: 700, currencyCode: "RUB", details: "кофе, булочка и сок"))
        try context.save()

        let url = try export(.csv)
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            text.contains("\"кофе, булочка и сок\""),
            "Поле с запятой должно быть в кавычках"
        )
    }

    /// Метка кодировки в начале файла: без неё Excel открывает кириллицу
    /// кракозябрами, и выгрузка выглядит испорченной, хотя данные целы.
    func testCSVStartsWithByteOrderMark() throws {
        context.insert(Expense(amount: 100, details: "тест"))
        try context.save()

        let url = try export(.csv)
        let data = try Data(contentsOf: url)

        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
    }

    func testEmptyDatabaseExportsValidFile() throws {
        let url = try export(.json)
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertEqual((json?["captures"] as? [Any])?.count, 0)
    }

    func testFileNameCarriesExtension() throws {
        XCTAssertEqual(try export(.json).pathExtension, "json")
        XCTAssertEqual(try export(.csv).pathExtension, "csv")
    }
}
