import Foundation

/// Каскад разбора: правила, локальная модель, облако.
///
/// Порядок подчинён ощущению скорости. Правила отрабатывают мгновенно,
/// и их результат сразу уходит в интерфейс. Модели работают дольше и
/// уточняют разбор, когда пользователь уже видит созданную запись.
/// Поэтому конвейер отдаёт два результата: предварительный и окончательный.
struct ParsingPipeline: Sendable {

    /// Что получилось на каждом уровне.
    struct Outcome: Sendable {
        /// Мгновенный разбор правилами.
        let preliminary: ParsedIntent
        /// Лучший разбор из доступных: он и попадает в базу.
        let final: ParsedIntent
        /// Какие движки реально отработали.
        let enginesUsed: [ParsingEngine]
    }

    private let fastPath: IntentParsing
    private let localModel: IntentParsing?
    private let cloud: IntentParsing?

    init(
        fastPath: IntentParsing = FastPathParser(),
        localModel: IntentParsing? = nil,
        cloud: IntentParsing? = nil
    ) {
        self.fastPath = fastPath
        self.localModel = localModel
        self.cloud = cloud
    }

    /// Собирает конвейер под возможности устройства и настройки.
    @MainActor
    static func make(
        capabilities: Capabilities = .current,
        configuration: APIConfiguration = .default
    ) -> ParsingPipeline {
        var localModel: IntentParsing?

        #if canImport(FoundationModels)
        // Локальная модель требует и системы, и железа с Apple Intelligence.
        if capabilities.hasFoundationModels, #available(iOS 26.0, *) {
            localModel = FoundationModelsParser()
        }
        #endif

        var cloud: IntentParsing?
        if configuration.isCloudEnabled {
            switch configuration.backend {
            case .edgeFunction:
                cloud = CloudParser(client: EdgeFunctionClient(configuration: configuration))
            case .anthropicDirect:
                cloud = CloudParser(client: AnthropicClient(configuration: configuration))
            }
        }

        return ParsingPipeline(localModel: localModel, cloud: cloud)
    }

    // MARK: Выполнение

    /// Разбирает текст каскадом.
    /// - Parameter onPreliminary: вызывается сразу после разбора правилами,
    ///   до обращения к моделям. Через него интерфейс показывает результат,
    ///   не дожидаясь ничего.
    func run(
        text: String,
        context: ParsingContext,
        onPreliminary: (@Sendable (ParsedIntent) -> Void)? = nil
    ) async throws -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParsingError.emptyInput }

        var enginesUsed: [ParsingEngine] = []

        let preliminary = try await fastPath.parse(text: trimmed, context: context)
        enginesUsed.append(.fastPath)
        onPreliminary?(preliminary)

        var best = preliminary

        // Локальная модель: без сети, поэтому пробуем всегда, когда доступна.
        if let localModel, await localModel.isAvailable {
            do {
                let refined = try await localModel.parse(text: trimmed, context: context)
                best = Self.merge(base: best, refined: refined)
                enginesUsed.append(.foundationModels)
            } catch {
                // Отказ модели не должен ронять разбор: у нас уже есть
                // результат правил, и он лучше, чем ничего.
                Log.data.notice("Локальная модель не дала результата: \(error.localizedDescription)")
            }
        }

        // Облако: последний и самый точный уровень.
        if let cloud, await cloud.isAvailable {
            do {
                let refined = try await cloud.parse(text: trimmed, context: context)
                best = Self.merge(base: best, refined: refined)
                enginesUsed.append(.cloud)
            } catch {
                Log.data.notice("Облачный разбор не удался: \(error.localizedDescription)")
            }
        }

        return Outcome(preliminary: preliminary, final: best, enginesUsed: enginesUsed)
    }

    // MARK: Слияние

    /// Объединяет результаты двух движков.
    ///
    /// Побеждает движок с большей достоверностью, но идентификаторы
    /// совпавших сущностей переносятся из предыдущего результата. Это
    /// принципиально: по идентификатору материализатор поймёт, что запись
    /// нужно обновить, а не создать второй раз. Без переноса уточнение
    /// облаком порождало бы дубли всего, что уже успели создать правила.
    static func merge(base: ParsedIntent, refined: ParsedIntent) -> ParsedIntent {
        guard refined.engine.authority >= base.engine.authority else { return base }
        guard !refined.items.isEmpty else { return base }

        var unmatched = base.items
        var merged: [ParsedItem] = []

        for var item in refined.items {
            if let index = unmatched.firstIndex(where: { Self.isSameEntity($0, item) }) {
                // Сохраняем идентификатор и исходный фрагмент фразы:
                // модель могла переписать формулировку, но сущность та же.
                item.id = unmatched[index].id
                if item.sourceText.isEmpty { item.sourceText = unmatched[index].sourceText }
                unmatched.remove(at: index)
            }
            merged.append(item)
        }

        return ParsedIntent(
            items: merged,
            people: refined.people.isEmpty ? base.people : refined.people,
            projects: refined.projects.isEmpty ? base.projects : refined.projects,
            languageCode: refined.languageCode ?? base.languageCode,
            confidence: refined.confidence,
            engine: refined.engine,
            duration: base.duration + refined.duration
        )
    }

    /// Одна ли это сущность в двух разборах.
    ///
    /// Сравнивать заголовки дословно бесполезно: модель переписывает
    /// формулировку. Поэтому смотрим на тип и на то, что определяет
    /// сущность по существу: сумму для расхода, день для напоминания,
    /// общие слова для задачи.
    static func isSameEntity(_ lhs: ParsedItem, _ rhs: ParsedItem) -> Bool {
        guard lhs.kind == rhs.kind else { return false }

        switch lhs.kind {
        case .expense:
            guard let left = lhs.amount, let right = rhs.amount else { return false }
            return left == right

        case .reminder:
            guard let left = lhs.dueDate, let right = rhs.dueDate else { return false }
            // Совпадение с точностью до часа: модель может уточнить минуты,
            // но это по-прежнему то же самое напоминание.
            return abs(left.timeIntervalSince(right)) < 3600

        case .task, .note:
            return titlesOverlap(lhs, rhs)
        }
    }

    /// Есть ли у формулировок общие значимые слова.
    private static func titlesOverlap(_ lhs: ParsedItem, _ rhs: ParsedItem) -> Bool {
        let leftWords = significantWords(lhs.title.isEmpty ? lhs.details : lhs.title)
        let rightWords = significantWords(rhs.title.isEmpty ? rhs.details : rhs.title)

        guard !leftWords.isEmpty, !rightWords.isEmpty else { return false }

        let common = leftWords.intersection(rightWords)
        let smaller = min(leftWords.count, rightWords.count)
        // Половина значимых слов совпала: считаем, что речь об одном и том же.
        return Double(common.count) / Double(smaller) >= 0.5
    }

    /// Слова длиннее трёх букв: короткие предлоги и союзы совпадают всегда
    /// и только мешают сравнению.
    private static func significantWords(_ text: String) -> Set<String> {
        let normalized = IntentKeywords.normalize(text)
        let words = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
        return Set(words)
    }
}
