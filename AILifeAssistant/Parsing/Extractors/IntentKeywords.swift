import Foundation

/// Словарь маркеров намерений на русском и английском.
///
/// Здесь сознательно лежат корни слов, а не полные формы: русский язык
/// склоняет всё, и «потратил», «потратила», «потрачу» должны ловиться одним
/// правилом. Проверка идёт по вхождению корня в нормализованный текст.
enum IntentKeywords {

    // MARK: Намерения

    /// Маркеры траты денег.
    static let expense: [String] = [
        // русский
        "купил", "купила", "куплю", "покупк", "потрат", "трач", "заплат",
        "оплат", "отдал", "стоил", "стоит", "обошл", "чек на", "счёт на",
        // английский
        "bought", "buy", "spent", "spend", "paid", "pay", "cost", "purchase",
        "expense", "bill for"
    ]

    /// Маркеры напоминания. Работают вместе с найденной датой:
    /// «напомни» без времени превращается в задачу, а не в напоминание.
    static let reminder: [String] = [
        "напомн", "не забыть", "не забудь", "разбуди",
        "remind", "reminder", "don't forget", "dont forget", "wake me"
    ]

    /// Маркеры задачи.
    ///
    /// Инфинитивы здесь так же важны, как служебные слова: люди диктуют
    /// дела именно ими. «Купить хлеб» без «купить» в списке проваливалось
    /// в заметку и до списка дел не доходило.
    static let task: [String] = [
        "нужно", "надо", "надобно", "сделать", "задач", "запланир",
        "позвон", "написа", "отправ", "заказ", "забрать", "встрет",
        "купить", "купл", "сходить", "съездить", "заехать", "оплатить",
        "продлить", "записаться", "забронировать", "починить", "постирать",
        "убрать", "приготовить", "получить", "вернуть", "сдать", "проверить",
        "need to", "have to", "must", "todo", "to do", "task", "call ",
        "write ", "send ", "order ", "pick up", "meet ", "buy "
    ]

    /// Служебные слова задачи: только они убираются из заголовка.
    ///
    /// Глагол действия остаётся: «позвонить Ване» это и есть суть дела,
    /// и раньше очистка заголовка съедала именно его, оставляя «Ване».
    static let taskFillers: [String] = [
        "нужно", "надо", "надобно", "задач", "запланир",
        "need to", "have to", "must", "todo", "to do", "task"
    ]

    /// Маркеры заметки или идеи.
    static let note: [String] = [
        "заметк", "идея", "идею", "мысл", "запиш", "запомн", "подумать о",
        "note", "idea", "thought", "remember that"
    ]

    // MARK: Приоритет

    static let highPriority: [String] = [
        "срочно", "важно", "критично", "asap", "urgent", "important", "critical"
    ]

    static let lowPriority: [String] = [
        "когда-нибудь", "не срочно", "несрочно", "не важно", "неважно",
        "не критично", "не горит", "потом",
        "someday", "later", "low priority", "not urgent"
    ]

    // MARK: Категории расходов

    /// Слова-подсказки для категорий. Проверяются по тому же принципу корней.
    static let expenseCategories: [ExpenseCategory: [String]] = [
        .food: [
            "кофе", "еда", "обед", "ужин", "завтрак", "продукт", "ресторан",
            "кафе", "пицц", "суши", "бар", "столов", "перекус",
            "coffee", "lunch", "dinner", "breakfast", "food", "grocer",
            "restaurant", "cafe", "pizza", "sushi", "snack"
        ],
        .transport: [
            "такси", "метро", "автобус", "бензин", "заправк", "парковк",
            "проезд", "каршеринг", "самокат", "яндекс го", "убер",
            "taxi", "uber", "metro", "subway", "bus", "gas", "fuel",
            "parking", "ride", "scooter"
        ],
        .housing: [
            "аренд", "квартплат", "коммуналк", "жкх", "ипотек", "квартир",
            "rent", "mortgage", "utilities", "apartment"
        ],
        .health: [
            "аптек", "лекарств", "врач", "стоматолог", "анализ", "клиник",
            "витамин", "страховк",
            "pharmacy", "medicine", "doctor", "dentist", "clinic", "insurance"
        ],
        .entertainment: [
            "кино", "театр", "концерт", "игр", "подписк", "нетфликс",
            "музе", "выставк",
            "movie", "cinema", "theater", "concert", "game", "subscription",
            "netflix", "museum"
        ],
        .shopping: [
            "одежд", "обув", "магазин", "маркетплейс", "озон", "вайлдберриз",
            "техник", "гаджет", "подарок",
            "clothes", "shoes", "shop", "amazon", "gift", "gadget"
        ],
        .education: [
            "курс", "книг", "учебник", "обучен", "школ", "универ", "репетитор",
            "course", "book", "class", "tuition", "lesson", "tutor"
        ],
        .travel: [
            "билет", "отел", "гостиниц", "авиа", "поездк", "виза", "жиль на",
            "ticket", "hotel", "flight", "trip", "airbnb", "visa"
        ],
        .services: [
            "стрижк", "барбершоп", "химчистк", "ремонт", "мастер", "уборк",
            "маникюр", "сервис",
            "haircut", "barber", "cleaning", "repair", "service", "laundry"
        ]
    ]

    // MARK: Проверки

    /// Нормализация для поиска: нижний регистр, «ё» приводится к «е»,
    /// иначе «счёт» и «счет» считаются разными словами.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
    }

    /// Маркеры, которые являются законченными словами, а не корнями.
    ///
    /// Для них проверяются границы слова с обеих сторон. Без этого «надо»
    /// находилось внутри «надоело», «потом» внутри «потому», а «срочно»
    /// внутри «не срочно», и фраза получала смысл, обратный сказанному.
    private static let wholeWordMarkers: Set<String> = [
        "надо", "нужно", "надобно", "потом", "срочно", "важно", "критично",
        "сделать", "купить", "убрать", "вернуть", "сдать", "проверить",
        "must", "task", "later", "urgent", "important"
    ]

    /// Есть ли маркер в уже нормализованном тексте.
    static func matches(_ normalized: String, marker: String) -> Bool {
        guard wholeWordMarkers.contains(marker) else {
            // Корень слова: продолжение обязано быть, границу справа
            // требовать нельзя.
            return normalized.contains(marker)
        }

        let pattern = #"(?<![\p{L}])"#
            + NSRegularExpression.escapedPattern(for: marker)
            + #"(?![\p{L}])"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    /// Содержит ли текст хотя бы один маркер из набора.
    static func contains(_ text: String, any markers: [String]) -> Bool {
        let normalized = normalize(text)
        return markers.contains { matches(normalized, marker: normalize($0)) }
    }

    /// Сколько маркеров набора встретилось: используется как грубая мера
    /// уверенности, два совпадения надёжнее одного.
    static func matchCount(_ text: String, markers: [String]) -> Int {
        let normalized = normalize(text)
        return markers.reduce(into: 0) { count, marker in
            if matches(normalized, marker: normalize(marker)) { count += 1 }
        }
    }

    /// Категория расхода по словам фразы.
    static func expenseCategory(in text: String) -> ExpenseCategory? {
        let normalized = normalize(text)
        var best: (category: ExpenseCategory, hits: Int)?

        for (category, markers) in expenseCategories {
            let hits = markers.reduce(into: 0) { count, marker in
                if normalized.contains(normalize(marker)) { count += 1 }
            }
            guard hits > 0 else { continue }
            if best == nil || hits > best!.hits {
                best = (category, hits)
            }
        }
        return best?.category
    }

    /// Приоритет по словам фразы.
    ///
    /// Низкий проверяется первым: «срочно» это часть «не срочно», и при
    /// обратном порядке фраза «это не срочно» получала высокий приоритет,
    /// то есть ровно противоположный сказанному.
    static func priority(in text: String) -> Priority {
        if contains(text, any: lowPriority) { return .low }
        if contains(text, any: highPriority) { return .high }
        return .none
    }
}
