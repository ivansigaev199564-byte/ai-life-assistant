import SwiftData
import SwiftUI

/// Инбокс: все захваты по дням, свежие сверху.
struct TimelineView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(CaptureCoordinator.self) private var coordinator

    /// Сортировка на уровне запроса: SwiftData отдаёт готовый порядок,
    /// сортировать в представлении не нужно.
    @Query(sort: \CaptureItem.createdAt, order: .reverse)
    private var captures: [CaptureItem]

    @State private var searchText = ""

    var body: some View {
        Group {
            if captures.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .searchable(text: $searchText, prompt: "Поиск по записям")
    }

    // MARK: Список

    private var list: some View {
        List {
            ForEach(groupedCaptures, id: \.day) { group in
                Section {
                    ForEach(group.items) { capture in
                        CaptureRowView(capture: capture)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(capture)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if capture.status == .failed {
                                    Button {
                                        retry(capture)
                                    } label: {
                                        Label("Повторить", systemImage: "arrow.clockwise")
                                    }
                                    .tint(.blue)
                                }
                            }
                    }
                } header: {
                    Text(group.title)
                }
            }

            // Пустое место под нижней панелью захвата, иначе кнопка
            // перекрывает последнюю строку списка.
            Color.clear
                .frame(height: 90)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Пока пусто", systemImage: "tray")
        } description: {
            Text("Нажмите «Говорить» и скажите что угодно. Запись появится здесь через мгновение.")
        }
    }

    // MARK: Данные

    private struct DayGroup {
        let day: Date
        let title: String
        let items: [CaptureItem]
    }

    private var filteredCaptures: [CaptureItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return captures }
        return captures.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var groupedCaptures: [DayGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filteredCaptures) { capture in
            calendar.startOfDay(for: capture.createdAt)
        }

        return groups
            .map { day, items in
                DayGroup(day: day, title: Self.title(for: day), items: items)
            }
            .sorted { $0.day > $1.day }
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Сегодня" }
        if calendar.isDateInYesterday(day) { return "Вчера" }
        return day.formatted(.dateTime.day().month(.wide).year())
    }

    // MARK: Действия

    private func delete(_ capture: CaptureItem) {
        // Аудиофайл живёт вне базы, поэтому удаляем его отдельно.
        if let fileName = capture.audioFileName {
            RecordingStore().delete(fileName: fileName)
        }
        modelContext.delete(capture)
        do {
            try modelContext.save()
        } catch {
            Log.data.error("Не удалось удалить захват: \(error.localizedDescription)")
        }
    }

    private func retry(_ capture: CaptureItem) {
        // На Этапе 2 здесь будет повторный запуск разбора.
        // Пока просто возвращаем запись в очередь.
        capture.status = .pending
        capture.failureReason = nil
        try? modelContext.save()
    }
}

#Preview {
    let preview = AppEnvironment.makeForTesting()
    return NavigationStack {
        TimelineView()
            .environment(preview.coordinator)
    }
    .modelContainer(preview.container)
}
