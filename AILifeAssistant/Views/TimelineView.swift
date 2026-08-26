import SwiftData
import SwiftUI

/// Лента записей, сгруппированная по дням.
///
/// Список собран на LazyVStack, а не на List: карточкам нужны собственные
/// отступы, скругления и переносимые плашки, а системный список навязывает
/// свою геометрию строк и разделители.
struct TimelineView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(ProcessingQueue.self) private var processingQueue

    @Query(sort: \CaptureItem.createdAt, order: .reverse)
    private var captures: [CaptureItem]

    @State private var searchText = ""
    @State private var captureToDelete: CaptureItem?

    var body: some View {
        Group {
            if captures.isEmpty {
                EmptyStateView(
                    symbol: "mic.badge.plus",
                    title: "Пока пусто",
                    // Конкретная фраза вместо приглашения «скажите что угодно»:
                    // от неопределённости человек как раз и молчит.
                    message: "Нажмите «Говорить» и скажите, например: «купил кофе за 300» или «напомни завтра позвонить в банк»."
                )
                .frame(maxHeight: .infinity, alignment: .center)
            } else if filteredCaptures.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "Ничего не найдено",
                    message: "Попробуйте другое слово из записи."
                )
                .frame(maxHeight: .infinity, alignment: .center)
            } else {
                content
            }
        }
        .searchable(text: $searchText, prompt: "Поиск по записям")
        .confirmationDialog(
            "Удалить запись?",
            isPresented: Binding(
                get: { captureToDelete != nil },
                set: { isPresented in if !isPresented { captureToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                if let captureToDelete { delete(captureToDelete) }
                captureToDelete = nil
            }
            Button("Отмена", role: .cancel) { captureToDelete = nil }
        } message: {
            Text("Вместе с записью удалятся созданные из неё заметки, задачи, напоминания и расходы.")
        }
    }

    // MARK: Содержимое

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.md, pinnedViews: .sectionHeaders) {
                ForEach(groupedCaptures, id: \.day) { group in
                    Section {
                        ForEach(group.items) { capture in
                            NavigationLink {
                                CaptureDetailView(capture: capture, processingQueue: processingQueue)
                            } label: {
                                CaptureRowView(capture: capture)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if capture.status == .failed || capture.parsedAt == nil {
                                    Button {
                                        Task { await processingQueue.retry(capture) }
                                    } label: {
                                        Label("Разобрать заново", systemImage: "arrow.clockwise")
                                    }
                                }
                                Button(role: .destructive) {
                                    captureToDelete = capture
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    } header: {
                        dayHeader(group)
                    }
                }

                // Место под кнопкой записи, чтобы последняя карточка
                // не пряталась за ней.
                Color.clear.frame(height: 96)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.xxs)
        }
        .scrollDismissesKeyboard(.immediately)
        .animation(DS.Motion.enter, value: captures.count)
    }

    /// Заголовок дня остаётся у верхней кромки при прокрутке: так всегда
    /// понятно, какой день сейчас на экране.
    private func dayHeader(_ group: DayGroup) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(group.title)
                .font(DS.Font.micro)
                .kerning(0.8)
                .foregroundStyle(DS.Palette.textTertiary)

            Text("\(group.items.count)")
                .font(DS.Font.micro)
                .foregroundStyle(DS.Palette.textTertiary.opacity(0.7))

            Spacer()
        }
        .padding(.vertical, DS.Spacing.xxs)
        .padding(.horizontal, DS.Spacing.xxs)
        .background {
            Rectangle()
                .fill(DS.Palette.background)
                .padding(.horizontal, -DS.Spacing.md)
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
        return day.formatted(.dateTime.day().month(.wide))
    }

    // MARK: Действия

    private func delete(_ capture: CaptureItem) {
        // Аудиофайл живёт вне базы, поэтому удаляется отдельно.
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
}

#Preview {
    let preview = AppEnvironment.makeForTesting()
    return NavigationStack {
        TimelineView()
            .environment(preview.coordinator)
            .environment(preview.processingQueue)
            .background(DS.Palette.background)
    }
    .modelContainer(preview.container)
}
