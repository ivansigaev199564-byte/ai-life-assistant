import Foundation
import XCTest
@testable import AILifeAssistant

/// Ссылки внутрь приложения. Собирает их виджет, разбирает приложение,
/// поэтому проверяется именно круг: собрали, разобрали, получили то же самое.
final class DeepLinkTests: XCTestCase {

    func testRoundTrip() throws {
        let identifier = UUID()

        let links: [DeepLink] = [
            .today,
            .capture(identifier),
            .reminder(identifier),
            .task(identifier)
        ]

        for link in links {
            let url = try XCTUnwrap(link.url, "Ссылка \(link) должна собираться")
            XCTAssertEqual(DeepLink(url: url), link, "Разбор \(url) вернул не то, что собрали")
        }
    }

    func testRejectsForeignScheme() {
        let url = URL(string: "habitapp://today")
        XCTAssertNil(url.flatMap(DeepLink.init(url:)), "Чужая схема не наша забота")
    }

    func testRejectsUnknownHost() {
        let url = URL(string: "ailife://unknown/\(UUID().uuidString)")
        XCTAssertNil(url.flatMap(DeepLink.init(url:)))
    }

    /// Ссылка без идентификатора никуда не ведёт: открывать «какую-то»
    /// задачу хуже, чем не открывать ничего.
    func testRejectsMissingIdentifier() {
        for host in ["capture", "reminder", "task"] {
            let url = URL(string: "ailife://\(host)")
            XCTAssertNil(url.flatMap(DeepLink.init(url:)), "\(host) без идентификатора должен отбрасываться")
        }
    }

    func testRejectsBrokenIdentifier() {
        let url = URL(string: "ailife://task/не-uuid")
        XCTAssertNil(url.flatMap(DeepLink.init(url:)))
    }
}
