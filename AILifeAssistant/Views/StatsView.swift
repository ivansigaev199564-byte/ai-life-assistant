import SwiftData
import SwiftUI

/// Куда уходят деньги.
///
/// Единственный экран, который открывают не по делу, а чтобы понять.
/// Поэтому здесь не таблица цифр, а ответы на три вопроса: сколько всего,
/// на что больше всего и где именно.
struct StatsView: View {

    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Expense.spentAt, order: .reverse)
    private var expenses: [Expense]

    @State private var period: Period = .month

    enum Period: String, CaseIterable, Identifiable {
        case week, month, year

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: return "Неделя"
            case .month: return "Месяц"
            case .year: return "Год"
            }
        }

        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .year: return 365
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    EmptyStateView(
                        symbol: "chart.pie",
                        title: "Пока нечего показывать",
                        message: "Скажите «купил кофе за 300», и трата появится здесь."
                    )
                    .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    content
                }
            }
            .background(DS.Palette.background)
            .navigationTitle("Расходы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Picker("Период", selection: $period) {
                    ForEach(Period.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                totalCard
                categoriesCard

                if !topMerchants.isEmpty {
                    merchantsCard
                }
            }
            .padding(DS.Spacing.md)
            .padding(.bottom, DS.Spacing.lg)
        }
    }

    // MARK: Итог

    private var totalCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text("Всего за " + period.title.lowercased())
                    .font(DS.Font.micro)
                    .foregroundStyle(DS.Palette.textTertiary)

                Text(total.formatted(.currency(code: currencyCode)))
                    .font(DS.Font.display)
                    .foregroundStyle(DS.Palette.textPrimary)

                // Средний расход в день говорит больше общей суммы: по нему
                // видно, укладывается ли человек в привычный ритм.
                Text("в среднем " + dailyAverage.formatted(.currency(code: currencyCode)) + " в день")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)

                // Траты в других валютах молча выпадали из итога: человек
                // видел сумму меньше настоящей и не понимал почему.
                if otherCurrencyCount > 0 {
                    Text(otherCurrencyNote)
                        .font(DS.Font.micro)
                        .foregroundStyle(DS.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Категории

    private var categoriesCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: "По категориям")

            SurfaceCard {
                VStack(spacing: DS.Spacing.sm) {
                    ForEach(categoryTotals, id: \.category) { entry in
                        categoryRow(category: entry.category, amount: entry.amount)
                    }
                }
            }
        }
    }

    private func categoryRow(category: ExpenseCategory, amount: Decimal) -> some View {
        let share = total > 0
            ? NSDecimalNumber(decimal: amount / total).doubleValue
            : 0

        return VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.EntityColor.expense)
                    .frame(width: 18)

                Text(category.displayName)
                    .font(DS.Font.entityTitle)
                    .foregroundStyle(DS.Palette.textPrimary)

                Spacer(minLength: DS.Spacing.xs)

                Text(amount.formatted(.currency(code: currencyCode)))
                    .font(DS.Font.amount)
                    .foregroundStyle(DS.Palette.textPrimary)

                Text("\(Int(share * 100)) %")
                    .font(DS.Font.micro)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .frame(width: 40, alignment: .trailing)
            }

            // Полоса доли: она читается взглядом, проценты требуют чтения.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Palette.surfaceElevated)
                    Capsule()
                        .fill(DS.EntityColor.expense)
                        .frame(width: max(2, geometry.size.width * share))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            category.displayName + ", "
                + amount.formatted(.currency(code: currencyCode))
                + ", \(Int(share * 100)) процентов"
        )
    }

    // MARK: Места

    private var merchantsCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: "Куда чаще всего")

            SurfaceCard {
                VStack(spacing: DS.Spacing.sm) {
                    ForEach(topMerchants, id: \.name) { entry in
                        HStack(spacing: DS.Spacing.xs) {
                            Text(entry.name)
                                .font(DS.Font.entityTitle)
                                .foregroundStyle(DS.Palette.textPrimary)
                                .lineLimit(1)

                            Text("\(entry.count)")
                                .font(DS.Font.micro)
                                .foregroundStyle(DS.Palette.textTertiary)

                            Spacer(minLength: DS.Spacing.xs)

                            Text(entry.amount.formatted(.currency(code: currencyCode)))
                                .font(DS.Font.amount)
                                .foregroundStyle(DS.Palette.textPrimary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Данные

    private var filtered: [Expense] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -period.days, to: .now) ?? .now
        return expenses.filter { $0.spentAt >= cutoff }
    }

    /// Валюта берётся у самой свежей траты: складывать разные валюты
    /// бессмысленно, а курсов у приложения нет и быть не должно.
    private var currencyCode: String {
        filtered.first?.currencyCode ?? Locale.current.currency?.identifier ?? "RUB"
    }

    private var sameCurrency: [Expense] {
        filtered.filter { $0.currencyCode == currencyCode }
    }

    private var total: Decimal {
        sameCurrency.reduce(into: Decimal(0)) { $0 += $1.amount }
    }

    /// Сколько трат не попало в итог из-за другой валюты.
    private var otherCurrencyCount: Int {
        filtered.count - sameCurrency.count
    }

    private var otherCurrencyNote: String {
        let codes = Set(filtered.map(\.currencyCode)).subtracting([currencyCode]).sorted()
        let list = codes.joined(separator: ", ")
        return "Ещё \(otherCurrencyCount) трат в другой валюте (\(list)) в итог не входят."
    }

    private var dailyAverage: Decimal {
        total / Decimal(period.days)
    }

    private var categoryTotals: [(category: ExpenseCategory, amount: Decimal)] {
        Dictionary(grouping: sameCurrency, by: \.category)
            .map { key, value in
                (category: key, amount: value.reduce(into: Decimal(0)) { $0 += $1.amount })
            }
            .sorted { $0.amount > $1.amount }
    }

    private var topMerchants: [(name: String, amount: Decimal, count: Int)] {
        let named = sameCurrency.compactMap { expense -> (String, Decimal)? in
            guard let merchant = expense.merchant, !merchant.isEmpty else { return nil }
            return (merchant, expense.amount)
        }

        return Dictionary(grouping: named, by: \.0)
            .map { key, value in
                (name: key, amount: value.reduce(into: Decimal(0)) { $0 += $1.1 }, count: value.count)
            }
            .sorted { $0.amount > $1.amount }
            .prefix(5)
            .map { $0 }
    }
}
