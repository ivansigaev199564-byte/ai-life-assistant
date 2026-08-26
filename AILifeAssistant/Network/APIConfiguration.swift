import Foundation

/// Настройки обращения к облачной модели.
///
/// На этом этапе облако выключено: ключи не должны лежать в приложении,
/// а серверный посредник появится вместе с Supabase на Этапе 3. Код клиента
/// написан и покрыт тестами заранее, чтобы включение свелось к смене флага.
struct APIConfiguration: Sendable, Equatable {

    /// Куда ходить за разбором.
    enum Backend: String, Sendable {
        /// Напрямую в Anthropic. Требует ключа на устройстве, поэтому
        /// допустимо только в отладочных сборках.
        case anthropicDirect
        /// Через собственную функцию, где ключ хранится на сервере.
        case edgeFunction
    }

    /// Главный выключатель. Пока выключено, конвейер работает на локальных
    /// движках и не делает ни одного сетевого запроса.
    var isCloudEnabled: Bool

    var backend: Backend

    /// Модель Anthropic. По умолчанию самая способная: разбор смысла живой
    /// речи с оговорками распознавания это не та задача, где стоит экономить
    /// на качестве. Значение выносится в настройки, чтобы можно было
    /// сравнить с более дешёвыми моделями на своих фразах.
    var model: String

    /// Ограничение ответа. Структура разбора короткая: несколько сущностей
    /// с полями, этого запаса достаточно с большим избытком.
    var maxTokens: Int

    /// Глубина рассуждений. Извлечение сущностей из одной фразы это простая
    /// задача, и низкое значение заметно сокращает и задержку, и стоимость.
    var effort: String

    /// Адрес функции-посредника, заполняется на Этапе 3.
    var edgeFunctionURL: URL?

    var requestTimeout: TimeInterval
    var maxRetries: Int

    static let `default` = APIConfiguration(
        isCloudEnabled: false,
        backend: .edgeFunction,
        model: "claude-opus-5",
        maxTokens: 4096,
        effort: "low",
        edgeFunctionURL: nil,
        requestTimeout: 20,
        maxRetries: 2
    )

    /// Версия API Anthropic, обязательный заголовок каждого запроса.
    static let anthropicVersion = "2023-06-01"
    static let anthropicMessagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
}
