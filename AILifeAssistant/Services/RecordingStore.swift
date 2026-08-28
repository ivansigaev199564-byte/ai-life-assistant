import Foundation

/// Хранилище аудиозаписей захватов.
///
/// В базе лежит только имя файла: путь к контейнеру приложения меняется
/// между запусками и обновлениями, поэтому абсолютный путь хранить нельзя.
struct RecordingStore: Sendable {

    /// Сколько дней держать записи. Текст разобран и сохранён, аудио нужно
    /// лишь для перепроверки спорных случаев, поэтому долго его не храним.
    static let retentionDays = 14

    /// FileManager не Sendable, поэтому храним не экземпляр, а обращаемся
    /// к общему объекту по месту: операции этого типа потокобезопасны.
    private var fileManager: FileManager { .default }

    /// Каталог записей внутри Application Support, исключён из резервных копий.
    var directory: URL {
        get throws {
            let base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let folder = base.appendingPathComponent("Recordings", isDirectory: true)

            if !fileManager.fileExists(atPath: folder.path) {
                // Голос это самое чувствительное, что есть в приложении.
                // completeUnlessOpen, а не complete: уже открытый файл
                // продолжает писаться, если экран погас во время записи,
                // но украденный заблокированный телефон записи не отдаёт.
                try fileManager.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
                )
                var mutable = folder
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? mutable.setResourceValues(values)
            } else {
                // Каталог мог быть создан прежней версией приложения
                // без класса защиты.
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: folder.path
                )
            }
            return folder
        }
    }

    /// Новый файл для записи. Имя совпадает с идентификатором захвата,
    /// поэтому связь «запись, файл» восстанавливается даже без базы.
    func makeRecordingURL(for captureID: UUID) throws -> URL {
        try directory.appendingPathComponent("\(captureID.uuidString).wav")
    }

    /// Полный путь по имени файла из базы.
    func url(forFileName fileName: String) throws -> URL {
        try directory.appendingPathComponent(fileName)
    }

    func fileExists(named fileName: String) -> Bool {
        guard let url = try? url(forFileName: fileName) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func delete(fileName: String) {
        guard let url = try? url(forFileName: fileName) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Суммарный размер каталога в байтах, показывается в настройках.
    func totalSize() -> Int64 {
        guard let directory = try? directory,
              let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey]
              ) else { return 0 }

        return contents.reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
    }

    /// Удаляет записи старше срока хранения. Вызывается при запуске
    /// и из фоновой задачи обслуживания.
    @discardableResult
    func pruneOldRecordings(olderThan days: Int = retentionDays) -> Int {
        guard let directory = try? directory,
              let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return 0 }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var removed = 0

        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                Log.data.error("Не удалось удалить запись \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if removed > 0 {
            Log.data.notice("Удалено старых записей: \(removed)")
        }
        return removed
    }

    func deleteAll() {
        guard let directory = try? directory,
              let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in contents {
            try? fileManager.removeItem(at: url)
        }
    }
}
