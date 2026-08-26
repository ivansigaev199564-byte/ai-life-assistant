import AppIntents
import SwiftUI
import WidgetKit

/// Элемент Пункта управления для быстрой записи.
///
/// Нужен тем, у кого нет кнопки действия: на iPhone до 15 Pro это
/// единственный способ начать запись за одно движение, не разблокируя
/// телефон и не ища иконку на экране.
@available(iOS 18.0, *)
struct CaptureControl: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ivans.ailifeassistant.capture") {
            ControlWidgetButton(action: ControlCaptureIntent()) {
                Label("Записать", systemImage: "mic.fill")
            }
        }
        .displayName("Быстрая запись")
        .description("Начинает голосовую запись в AI Assistant")
    }
}

/// Виджет на экране блокировки.
///
/// Показывает не данные, а кнопку: смысл продукта в том, чтобы поймать
/// мысль за секунду, и виджет здесь ради одного касания, а не ради
/// отображения списка дел, который всё равно не прочитать мельком.
struct QuickCaptureWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.ivans.ailifeassistant.quickcapture",
            provider: QuickCaptureProvider()
        ) { entry in
            QuickCaptureWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Быстрая запись")
        .description("Кнопка записи на экране блокировки и домашнем экране")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .systemSmall
        ])
    }
}

struct QuickCaptureEntry: TimelineEntry {
    let date: Date
}

/// Провайдер без данных: виджету нечего обновлять, он всегда одинаковый.
/// Поэтому политика обновления никогда не срабатывает, и виджет не тратит
/// бюджет обновлений системы.
struct QuickCaptureProvider: TimelineProvider {

    func placeholder(in context: Context) -> QuickCaptureEntry {
        QuickCaptureEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickCaptureEntry) -> Void) {
        completion(QuickCaptureEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickCaptureEntry>) -> Void) {
        completion(Timeline(entries: [QuickCaptureEntry(date: .now)], policy: .never))
    }
}

struct QuickCaptureWidgetView: View {

    @Environment(\.widgetFamily) private var family

    let entry: QuickCaptureEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title3)
            }
            .widgetURL(Self.captureURL)

        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                Text("Записать")
                    .font(.headline)
            }
            .widgetURL(Self.captureURL)

        default:
            VStack(spacing: 8) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)

                Text("Записать")
                    .font(.headline)

                Text("Скажите что угодно")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .widgetURL(Self.captureURL)
        }
    }

    /// Схема совпадает с той, что объявлена в приложении: нажатие виджета
    /// открывает его и сразу начинает запись.
    private static let captureURL = URL(string: "habitapp://capture?source=widget")
}
