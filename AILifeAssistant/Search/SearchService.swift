import Foundation
import Observation
import SwiftData

/// Поиск по записям.
///
/// Работает в два захода. Сначала локальный проход по базе: он мгновенный,
/// не требует сети и покрывает большинство запросов, потому что человек
/// обычно ищет слово, которое сам и произнёс. Затем, если есть связь,
/// подключается серверный смысловой поиск и дополняет выдачу тем,
/// что не находится дословно: «сколько ушло на обеды» найдёт запись
/// «потратил 600 в столовой».
@MainActor
@Observable
final class SearchService {

    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false
    /// Дополнена ли выдача смысловым поиском.
    private(set) var usedSemanticSearch = false

    private let modelContext: ModelContext
    private let networkMonitor: NetworkMonitor
    private let sessionProvider: () -> String?
    private let session: URLSession

    /// Задача текущего серверного запроса: при новом вводе прошлая отменяется,
    /// иначе ответы приходят вразнобой и выдача прыгает.
    private var remoteTask: Task<Void, Never>?

    /// Задача отложенного поиска.
    private var searchTask: Task<Void, Never>?

    /// Пауза перед поиском.
    ///
    /// Человек печатает быстрее, чем читает выдачу. Без паузы слово из пяти
    /// букв это пять полных проходов по базе и пять сетевых запросов,
    /// из которых нужен один, а поле ввода начинает терять символы.
    private static let debounce = Duration.milliseconds(250)

    /// Сколько строк каждого типа поднимать за раз: на экран всё равно
    /// помещается заметно меньше.
    private static let localFetchLimit = 40

    init(
        modelContext: ModelContext,
        networkMonitor: NetworkMonitor,
        sessionProvider: @escaping () -> String? = { nil },
        session: URLSession = .shared
    ) {
        self.modelContext = modelContext
        self.networkMonitor = networkMonitor
        self.sessionProvider = sessionProvider
        self.session = session
    }

    // MARK: Поиск

    func search(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        remoteTask?.cancel()
        searchTask?.cancel()
        usedSemanticSearch = false

        guard query.count >= 2 else {
            results = []
            isSearching = false
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }

            // Локальные результаты показываются сразу: ждать сеть ради поиска
            // по собственным заметкам пользователь не должен.
            self.results = self.localResults(for: query)

            guard self.canSearchRemotely else { return }

            self.isSearching = true
            self.remoteTask = Task { [weak self] in
                await self?.appendRemoteResults(for: query)
            }
        }
    }

    func clear() {
        remoteTask?.cancel()
        searchTask?.cancel()
        results = []
        isSearching = false
        usedSemanticSearch = false
    }

    private var canSearchRemotely: Bool {
        SupabaseConfiguration.isConfigured
            && networkMonitor.isOnline
            && sessionProvider() != nil
    }

    // MARK: Локальный поиск

    /// Проход по локальной базе.
    ///
    /// Условие уходит в базу предикатом, а не фильтрует поднятые в память
    /// таблицы. Цена решения: поиск по названию категории расхода пропал,
    /// оно вычисляемое и в предикат не переводится. Взамен экран перестал
    /// подниматься на несколько секунд при вводе первой буквы.
    private func localResults(for query: String) -> [SearchResult] {
        var found: [SearchResult] = []

        // Предикаты уходят в SQL и приносят только подходящие строки.
        // Раньше каждая из пяти таблиц поднималась целиком и фильтровалась
        // в памяти дорогим сравнением с учётом локали.
        found += fetch(
            FetchDescriptor<CaptureItem>(
                predicate: #Predicate { $0.text.localizedStandardContains(query) },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        ).map {
            SearchResult(
                id: $0.id,
                kind: .capture,
                title: String($0.previewText.prefix(80)),
                snippet: Self.snippet($0.text),
                occurredAt: $0.createdAt,
                origin: .local,
                score: Self.localScore(text: $0.text, query: query)
            )
        }

        found += fetch(
            FetchDescriptor<Note>(
                predicate: #Predicate {
                    $0.title.localizedStandardContains(query)
                        || $0.body.localizedStandardContains(query)
                },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        ).map {
            SearchResult(
                id: $0.id,
                kind: .note,
                title: $0.displayTitle,
                snippet: Self.snippet($0.body),
                occurredAt: $0.createdAt,
                origin: .local,
                score: Self.localScore(text: $0.displayTitle + " " + $0.body, query: query)
            )
        }

        found += fetch(
            FetchDescriptor<TaskItem>(
                predicate: #Predicate {
                    $0.title.localizedStandardContains(query)
                        || $0.details.localizedStandardContains(query)
                },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        ).map {
            SearchResult(
                id: $0.id,
                kind: .task,
                title: $0.title,
                snippet: Self.snippet($0.details),
                occurredAt: $0.createdAt,
                origin: .local,
                score: Self.localScore(text: $0.title, query: query)
            )
        }

        found += fetch(
            FetchDescriptor<Reminder>(
                predicate: #Predicate {
                    $0.title.localizedStandardContains(query)
                        || $0.details.localizedStandardContains(query)
                },
                sortBy: [SortDescriptor(\.fireDate, order: .reverse)]
            )
        ).map {
            SearchResult(
                id: $0.id,
                kind: .reminder,
                title: $0.title,
                snippet: Self.snippet($0.details),
                occurredAt: $0.fireDate,
                origin: .local,
                score: Self.localScore(text: $0.title, query: query)
            )
        }

        found += fetch(
            FetchDescriptor<Expense>(
                // Только по описанию: генератор SQL в SwiftData не умеет
                // подставлять значение вместо nil внутри условия и падает
                // на опциональном названии места. Поиск по мерчанту вернётся
                // отдельным полем модели.
                predicate: #Predicate { $0.details.localizedStandardContains(query) },
                sortBy: [SortDescriptor(\.spentAt, order: .reverse)]
            )
        ).map {
            SearchResult(
                id: $0.id,
                kind: .expense,
                title: $0.details.isEmpty ? $0.category.displayName : $0.details,
                snippet: $0.formattedAmount,
                occurredAt: $0.spentAt,
                origin: .local,
                score: Self.localScore(text: $0.details, query: query)
            )
        }

        return found.sorted { left, right in
            left.score == right.score
                ? left.occurredAt > right.occurredAt
                : left.score > right.score
        }
    }

    /// Выборка с общим ограничением по числу строк.
    private func fetch<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) -> [Model] {
        var limited = descriptor
        limited.fetchLimit = Self.localFetchLimit
        return (try? modelContext.fetch(limited)) ?? []
    }

    /// Отрывок для карточки результата.
    ///
    /// В выдачу больше не кладётся весь текст записи целиком: на экране
    /// видно две строки, а память и время уходили на всё.
    private static func snippet(_ text: String) -> String {
        String(text.prefix(200))
    }

    /// Простая оценка совпадения: точное вхождение в начале весит больше,
    /// чем где-то в середине длинного текста.
    private static func localScore(text: String, query: String) -> Double {
        let lowered = text.lowercased()
        let loweredQuery = query.lowercased()

        guard let range = lowered.range(of: loweredQuery) else { return 0.1 }

        let position = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
        let positionBonus = position == 0 ? 0.3 : 0.0
        let lengthRatio = Double(loweredQuery.count) / Double(max(lowered.count, 1))

        return min(1, 0.5 + positionBonus + lengthRatio * 0.2)
    }
}

// MARK: - Серверный поиск

private extension SearchService {

    /// Дополняет выдачу результатами сервера.
    ///
    /// Локальные результаты не заменяются, а дополняются: то, что уже нашлось
    /// на устройстве, пользователь видит мгновенно, и убирать это из-под
    /// курсора, когда придёт ответ сервера, недопустимо.
    func appendRemoteResults(for query: String) async {
        defer { isSearching = false }

        guard
            let configuration = SupabaseConfiguration.current,
            let token = sessionProvider()
        else { return }

        var request = URLRequest(
            url: configuration.functionsURL.appendingPathComponent("search")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["query": query, "limit": 20]
        )

        do {
            let (data, response) = try await session.data(for: request)

            guard !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            let decoded = try SupabaseRESTClient.decoder.decode(
                RemoteSearchResponse.self,
                from: data
            )

            merge(decoded)
        } catch {
            // Поиск не критичен: локальные результаты уже показаны,
            // и падать из-за недоступного сервера незачем.
            Log.data.notice("Серверный поиск не выполнен: \(error.localizedDescription)")
        }
    }

    /// Сливает серверные результаты с локальными, не создавая дублей.
    func merge(_ response: RemoteSearchResponse) {
        usedSemanticSearch = response.semantic

        let existingIDs = Set(results.map(\.id))

        let remote = response.results.compactMap { item -> SearchResult? in
            guard
                !existingIDs.contains(item.entityId),
                let kind = SearchResult.Kind(rawValue: item.entityType)
            else { return nil }

            return SearchResult(
                id: item.entityId,
                kind: kind,
                title: item.title,
                snippet: item.snippet,
                occurredAt: item.occurredAt,
                origin: .remote,
                score: item.score
            )
        }

        guard !remote.isEmpty else { return }

        // Локальные идут первыми: они точно совпали дословно, а серверные
        // дополняют их по смыслу. Мешать оценки нельзя, шкалы разные.
        results += remote
    }
}
