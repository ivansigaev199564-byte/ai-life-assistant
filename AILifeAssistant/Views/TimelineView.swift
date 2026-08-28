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

    /// Единственный путь удаления: он же сообщает синхронизации.
    /// Отсутствует в предпросмотре.
    @Environment(DeletionService.self) private var deletion: DeletionService?

    @Query(sort: \CaptureItem.createdAt, order: .reverse)
    private var captures: [CaptureItem]

    @State private var searchText = ""
    @State private var captureToDelete: CaptureItem?

    /// Режим выбора нескольких записей.
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var isConfirmingBatchDelete = false

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
        .safeAreaInset(edge: .top) {
            if isSelecting { selectionBar }
        }
        .confirmationDialog(
            batchDeleteTitle,
            isPresented: $isConfirmingBatchDelete,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) { deleteSelected() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(batchDeleteMessage)
        }
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
                            if isSelecting {
                                selectableRow(capture)
                            } else {
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
                                    Button {
                                        startSelecting(with: capture)
                                    } label: {
                                        Label("Выбрать несколько", systemImage: "checkmark.circle")
                                    }

                                    Button(role: .destructive) {
                                        captureToDelete = capture
                                    } label: {
                                        Label("Удалить", systemImage: "trash")
                                    }
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
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

    // MARK: Режим выбора

    /// Строка-переключатель. В режиме выбора карточка перестаёт открывать
    /// запись: одно и то же касание не может значить и «открыть», и «выбрать».
    private func selectableRow(_ capture: CaptureItem) -> some View {
        Button {
            toggleSelection(capture)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: selectedIDs.contains(capture.id)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selectedIDs.contains(capture.id)
                                     ? DS.Palette.accent
                                     : DS.Palette.textTertiary)

                CaptureRowView(capture: capture)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedIDs.contains(capture.id) ? [.isSelected] : [])
    }

    /// Панель управления выбором.
    private var selectionBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button("Готово") { stopSelecting() }
                .font(DS.Font.caption.weight(.semibold))

            Spacer()

            Text(selectedIDs.isEmpty
                 ? "Выберите записи"
                 : "Выбрано: \(selectedIDs.count)")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)

            Spacer()

            Button(selectedIDs.count == filteredCaptures.count ? "Снять всё" : "Выбрать всё") {
                toggleSelectAll()
            }
            .font(DS.Font.caption)

            Button {
                isConfirmingBatchDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selectedIDs.isEmpty)
            .foregroundStyle(selectedIDs.isEmpty ? DS.Palette.textTertiary : DS.Palette.danger)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(.regularMaterial)
    }

    private func startSelecting(with capture: CaptureItem) {
        withAnimation(DS.Motion.enter) {
            isSelecting = true
            selectedIDs = [capture.id]
        }
    }

    private func stopSelecting() {
        withAnimation(DS.Motion.enter) {
            isSelecting = false
            selectedIDs = []
        }
    }

    private func toggleSelection(_ capture: CaptureItem) {
        if selectedIDs.contains(capture.id) {
            selectedIDs.remove(capture.id)
        } else {
            selectedIDs.insert(capture.id)
        }
    }

    private func toggleSelectAll() {
        if selectedIDs.count == filteredCaptures.count {
            selectedIDs = []
        } else {
            selectedIDs = Set(filteredCaptures.map(\.id))
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

    /// Заголовок подтверждения с числом записей.
    private var batchDeleteTitle: String {
        "Удалить записи: " + String(selectedIDs.count) + "?"
    }

    /// Подтверждение говорит, что именно исчезнет.
    ///
    /// Массовое удаление необратимо, а вместе с записями уходит и всё,
    /// что из них разобрано. Человек должен видеть это до нажатия,
    /// а не узнать после.
    private var batchDeleteMessage: String {
        let selected = filteredCaptures.filter { selectedIDs.contains($0.id) }
        let derived = selected.reduce(into: 0) { $0 += $1.derivedItemsCount }

        guard derived > 0 else {
            return "Отменить это будет нельзя."
        }
        return "Вместе с ними удалятся созданные из них записи: \(derived). Отменить это будет нельзя."
    }

    private func deleteSelected() {
        let selected = captures.filter { selectedIDs.contains($0.id) }
        deletion?.delete(selected)
        stopSelecting()
    }

    private func delete(_ capture: CaptureItem) {
        deletion?.delete(capture)
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
