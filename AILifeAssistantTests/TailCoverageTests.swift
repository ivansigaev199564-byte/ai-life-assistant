import Foundation
import SwiftData
import XCTest
@testable import AILifeAssistant

/// Пробелы в покрытии, найденные аудитом. Каждый из этих тестов закрывает
/// место, где зелёная проверка ничего не проверяла.
final class TailCoverageTests: XCTestCase {

    private var context: ParsingContext {
        ParsingContext(
            referenceDate: Date(timeIntervalSince1970: 1_787_000_000),
            languageCode: "ru-RU",
            defaultCurrencyCode: "RUB"
        )
    }

    // MARK: Буква «ё»

    /// Прежний тест проверял только «список не пуст», что верно всегда.
    /// Падение было не в пустоте, а в заголовке: удаление маркера по
    /// диапазону с диакритикой роняло приложение.
    func testKeepsYoInsideWords() async throws {
        let parser = FastPathParser()

        let cases: [(phrase: String, mustContain: String)] = [
            ("напомни полить цветы", "полить"),
            ("нужно сделать чёткий план", "чёткий"),
            ("купил ёлку за 2000", "ёлку")
        ]

        for (phrase, fragment) in cases {
            let intent = try await parser.parse(text: phrase, context: context)
            let item = try XCTUnwrap(intent.items.first, "Фраза «\(phrase)» должна разобраться")

            let text = item.title.isEmpty ? item.details : item.title
            XCTAssertTrue(
                text.localizedCaseInsensitiveContains(fragment),
                "Из «\(phrase)» пропало «\(fragment)», получено: \(text)"
            )
        }
    }

    // MARK: Близкие имена

    /// Сопоставление по стему склеивало разных людей: «Марк» и «Мара»
    /// становились одним человеком, и записи уходили не туда.
    func testDoesNotMergeDifferentPeople() {
        // «Даня» и «Дана» здесь нет намеренно: они отличаются той же
        // гласной, что «Миша» и «Мише», и без словаря имён неразличимы.
        // Разбор выбран в пользу объединения падежей, потому что лишнюю
        // карточку человек объединит руками, а расщеплённую историю
        // заметить нечем.
        let pairs = [("Марк", "Мара"), ("Ольга", "Олег"), ("Инна", "Иван")]

        for (first, second) in pairs {
            let person = Person(name: first)
            XCTAssertFalse(
                person.matches(second),
                "«\(first)» и «\(second)» это разные люди"
            )
        }
    }

    func testMatchesSamePersonInDifferentCases() {
        let person = Person(name: "Миша")

        XCTAssertTrue(person.matches("Мише"))
        XCTAssertTrue(person.matches("Мишу"))
        XCTAssertTrue(person.matches("миша"))

        let igor = Person(name: "Игорь")
        XCTAssertTrue(igor.matches("Игорю"), "Мягкий знак это не другое имя")
    }

    // MARK: Люди в речи

    /// Извлечение людей не было покрыто вовсе, а оно заводит карточки
    /// само: каждая ошибка становится лишним человеком в списке.
    func testDoesNotTakePlacesAndBrandsForPeople() {
        let phrases = [
            "купил кофе в Пятёрочке",
            "заправился на Лукойле",
            "потратил 500 в Москве"
        ]

        for phrase in phrases {
            let people = PersonExtractor.extract(from: phrase, context: context)
            XCTAssertTrue(
                people.isEmpty,
                "Из «\(phrase)» человек взяться не должен, получено: \(people)"
            )
        }
    }

    func testFindsPersonAfterPreposition() {
        let people = PersonExtractor.extract(from: "напомни позвонить Мише", context: context)
        XCTAssertTrue(
            people.contains { $0.localizedCaseInsensitiveContains("миш") },
            "Получено: \(people)"
        )
    }

    // MARK: Часовые пояса

    /// Даты проверялись только в одном поясе и только от десяти утра.
    func testTomorrowMorningAcrossTimeZones() {
        let identifiers = ["Europe/Moscow", "Europe/Berlin", "America/New_York"]

        for identifier in identifiers {
            guard let zone = TimeZone(identifier: identifier) else {
                return XCTFail("Нет пояса \(identifier)")
            }

            // Поздний вечер: «завтра» не должно превратиться во «вчера»
            // из-за пересчёта в UTC.
            let context = ParsingContext(
                referenceDate: Date(timeIntervalSince1970: 1_787_000_000),
                timeZone: zone,
                languageCode: "ru-RU"
            )

            guard let result = DateExtractor.extract(from: "напомни завтра", context: context) else {
                return XCTFail("«Завтра» не разобралось в поясе \(identifier)")
            }

            let fireDate = DateExtractor.normalizedFireDate(from: result, context: context)
            XCTAssertGreaterThan(
                fireDate,
                context.referenceDate,
                "В поясе \(identifier) напоминание оказалось в прошлом"
            )
        }
    }

    // MARK: Очередь синхронизации

    /// Очередь переживает перезапуск: порядок операций важен, потому что
    /// удаление, обогнавшее создание, оставит на сервере лишнюю строку.
    func testQueueKeepsOrderAcrossRestart() throws {
        let fileName = "sync-queue-order-\(UUID().uuidString).json"
        let queue = SyncQueue(fileName: fileName)
        defer { queue.clear() }

        let first = UUID()
        let second = UUID()
        let third = UUID()

        queue.enqueue(.capture, id: first, kind: .upsert)
        queue.enqueue(.note, id: second, kind: .upsert)
        queue.enqueue(.capture, id: third, kind: .delete)

        // Новый экземпляр читает тот же файл: так же, как после перезапуска.
        let restored = SyncQueue(fileName: fileName)
        let operations = restored.next(limit: 10)

        XCTAssertEqual(operations.map(\.entityID), [first, second, third])
        XCTAssertEqual(operations.last?.kind, .delete)
    }
}
