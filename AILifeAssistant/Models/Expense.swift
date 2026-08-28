import Foundation
import SwiftData

/// Расход: сумма, валюта, категория, описание.
@Model
final class Expense {
    @Attribute(.unique) var id: UUID

    /// Сумма хранится в Decimal: Double округляет деньги неверно.
    var amount: Decimal

    /// Код валюты по ISO 4217: "RUB", "USD", "EUR".
    var currencyCode: String

    private var categoryRaw: String

    /// Описание словами: «кофе с Мишей», «такси до аэропорта».
    var details: String

    /// Где потрачено, если удалось выделить из речи.
    var merchant: String?

    /// Когда потрачено. По умолчанию момент захвата, но фраза
    /// «вчера потратил» сдвинет дату при разборе.
    var spentAt: Date

    var createdAt: Date
    var updatedAt: Date

    var confidence: Double
    var needsReview: Bool

    /// Значение поправил человек.
    ///
    /// Разбор не должен перезаписывать то, что пользователь исправил
    /// вручную или голосом: раньше правка суммы держалась только на том,
    /// что исправление переписывало текст записи подстрокой, а это могло
    /// задеть соседние числа в той же фразе.
    var isUserEdited: Bool = false


    private var syncStateRaw: String
    var remoteID: String?
    var lastSyncedAt: Date?

    var source: CaptureItem?

    /// Идентификатор элемента разбора, породившего эту запись.
    /// По нему уточняющий проход находит созданную сущность и обновляет её,
    /// вместо того чтобы создать вторую такую же.
    var parsedItemID: UUID?

    @Relationship(deleteRule: .nullify, inverse: \Person.expenses)
    var people: [Person] = []

    @Relationship(deleteRule: .nullify, inverse: \Project.expenses)
    var projects: [Project] = []

    init(
        id: UUID = UUID(),
        amount: Decimal,
        currencyCode: String = Locale.current.currency?.identifier ?? "RUB",
        category: ExpenseCategory = .other,
        details: String = "",
        merchant: String? = nil,
        spentAt: Date = .now,
        confidence: Double = 1,
        needsReview: Bool = false,
        source: CaptureItem? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.amount = amount
        self.currencyCode = currencyCode
        self.categoryRaw = category.rawValue
        self.details = details
        self.merchant = merchant
        self.spentAt = spentAt
        self.confidence = confidence
        self.needsReview = needsReview
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.syncStateRaw = SyncState.pendingUpload.rawValue
        self.source = source
    }

    var category: ExpenseCategory {
        get { ExpenseCategory(rawValue: categoryRaw) ?? .other }
        set {
            categoryRaw = newValue.rawValue
            updatedAt = .now
        }
    }

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .pendingUpload }
        set { syncStateRaw = newValue.rawValue }
    }

    /// Сумма с символом валюты по локали пользователя.
    var formattedAmount: String {
        amount.formatted(.currency(code: currencyCode))
    }
}
