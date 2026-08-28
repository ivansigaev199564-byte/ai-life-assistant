import AppIntents
import SwiftUI
import WidgetKit

/// Виджет «Сегодня»: что предстоит.
///
/// Смысл в том, чтобы не открывать приложение. Человек взглянул на экран
/// блокировки и понял, горит ли что-нибудь. Поэтому здесь нет ни статистики,
/// ни красивых итогов, только ближайшие дела и признак просрочки.
struct TodayWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.ivans.ailifeassistant.today",
            provider: TodayProvider()
        ) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Сегодня")
        .description("Ближайшие напоминания и задачи")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular
        ])
    }
}

struct TodayWidgetView: View {

    @Environment(\.widgetFamily) private var family

    let entry: TodayEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            lockScreenView
        case .systemSmall:
            smallView
        default:
            mediumView
        }
    }

    // MARK: Экран блокировки

    /// Место крошечное, поэтому только одно дело: пытаться уместить три
    /// значит сделать нечитаемыми все три.
    private var lockScreenView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let first = entry.items.first {
                HStack(spacing: 4) {
                    Image(systemName: first.isReminder ? "bell.fill" : "checkmark.circle")
                        .font(.system(size: 11))
                    Text(first.title)
                        .font(.headline)
                        .lineLimit(1)
                }

                if entry.totalCount > 1 {
                    Text(timeText(first) + " · ещё \(entry.totalCount - 1)")
                        .font(.caption)
                } else if let time = first.date {
                    Text(time.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                }
            } else {
                Text("На сегодня пусто")
                    .font(.headline)
            }
        }
        .widgetURL(Self.appURL)
    }

    // MARK: Малый виджет

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Сегодня")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if entry.totalCount > 0 {
                    Text("\(entry.totalCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tint)
                }
            }

            if entry.items.isEmpty {
                Spacer()
                Text("Всё сделано")
                    .font(.subheadline.weight(.medium))
                Spacer()
            } else {
                ForEach(entry.items.prefix(3)) { item in
                    itemRow(item, compact: true)
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(Self.appURL)
    }

    // MARK: Средний виджет

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Сегодня")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if entry.totalCount > entry.items.count {
                    Text("ещё \(entry.totalCount - entry.items.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if entry.items.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        Text("На сегодня ничего")
                            .font(.subheadline)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                ForEach(entry.items.prefix(4)) { item in
                    itemRow(item, compact: false)
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(Self.appURL)
    }

    // MARK: Строка дела

    /// Значок слева это настоящая галочка: дело закрывается прямо здесь,
    /// без открытия приложения. Ради этого виджет и нужен.
    private func itemRow(_ item: TodayItem, compact: Bool) -> some View {
        HStack(spacing: 6) {
            Button(intent: CompleteItemIntent(itemID: item.id, isReminder: item.isReminder)) {
                Image(systemName: item.isReminder ? "bell.fill" : "circle")
                    .font(.system(size: compact ? 9 : 11))
                    // Просроченное красное: это единственное, ради чего стоит
                    // тратить цвет в таком маленьком пространстве.
                    .foregroundStyle(item.isOverdue ? Color.red : Color.accentColor)
                    // Палец толще значка: цель нажатия расширена прозрачной
                    // областью, иначе промахнуться легче, чем попасть.
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Отметить выполненным: " + item.title)

            titleLink(item, compact: compact)

            Spacer(minLength: 4)

            if let time = item.date {
                Text(time.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(item.isOverdue ? Color.red : Color.secondary)
            }
        }
    }

    /// Заголовок ведёт к самой записи, а не в общий список.
    @ViewBuilder
    private func titleLink(_ item: TodayItem, compact: Bool) -> some View {
        let label = Text(item.title)
            .font(compact ? .caption2 : .caption)
            .lineLimit(1)

        if let destination = item.deepLink {
            Link(destination: destination) { label }
        } else {
            label
        }
    }

    private func timeText(_ item: TodayItem) -> String {
        guard let date = item.date else { return "без времени" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private static let appURL = DeepLink.today.url
}
