import Foundation
import XCTest
@testable import AILifeAssistant

/// Хранилище аудио: имена файлов, удаление и очистка по сроку.
final class RecordingStoreTests: XCTestCase {

    private let store = RecordingStore()

    override func tearDown() {
        store.deleteAll()
        super.tearDown()
    }

    /// Имя файла совпадает с идентификатором захвата: связь восстановима
    /// даже без базы.
    func testRecordingURLMatchesCaptureIdentifier() throws {
        let id = UUID()
        let url = try store.makeRecordingURL(for: id)

        XCTAssertEqual(url.lastPathComponent, "\(id.uuidString).wav")
        XCTAssertEqual(url.pathExtension, "wav")
    }

    func testDirectoryIsCreatedOnDemand() throws {
        let directory = try store.directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDeleteRemovesFile() throws {
        let id = UUID()
        let url = try store.makeRecordingURL(for: id)
        try Data([0x01, 0x02]).write(to: url)

        XCTAssertTrue(store.fileExists(named: url.lastPathComponent))
        store.delete(fileName: url.lastPathComponent)
        XCTAssertFalse(store.fileExists(named: url.lastPathComponent))
    }

    func testTotalSizeCountsWrittenBytes() throws {
        let url = try store.makeRecordingURL(for: UUID())
        try Data(repeating: 0, count: 2048).write(to: url)

        XCTAssertGreaterThanOrEqual(store.totalSize(), 2048)
    }

    /// Свежие записи очистка не трогает.
    func testPruneKeepsRecentRecordings() throws {
        let url = try store.makeRecordingURL(for: UUID())
        try Data([0x00]).write(to: url)

        let removed = store.pruneOldRecordings(olderThan: 14)

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(store.fileExists(named: url.lastPathComponent))
    }

    /// Файл с прошлой датой изменения удаляется.
    func testPruneRemovesOldRecordings() throws {
        let url = try store.makeRecordingURL(for: UUID())
        try Data([0x00]).write(to: url)

        let oldDate = Date().addingTimeInterval(-20 * 86400)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)

        let removed = store.pruneOldRecordings(olderThan: 14)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(store.fileExists(named: url.lastPathComponent))
    }
}
