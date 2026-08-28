import Foundation

/// Как движок синхронизации разговаривает с сервером.
///
/// Протокол введён ради проверяемости. Раньше движок сам создавал клиента
/// из статической конфигурации, прочитанной из Bundle: подменить её в тесте
/// было нечем, поэтому на весь слой отправки и приёма не существовало
/// ни одного теста, и любая регрессия уезжала незамеченной.
protocol SyncTransport: Sendable {

    /// Отправляет записи, обновляя существующие по первичному ключу.
    func upsert<Payload: Encodable & Sendable>(_ payloads: [Payload], into table: String) async throws

    /// Помечает записи удалёнными.
    func markDeleted(ids: Set<UUID>, in table: String) async throws

    /// Забирает страницу изменений после указанного момента.
    func fetchChanges<Payload: Decodable & Sendable>(
        from table: String,
        since: Date?,
        limit: Int
    ) async throws -> [Payload]
}

extension SupabaseRESTClient: SyncTransport {}
