import SwiftData
import SwiftUI

/// Всё, что относится к проекту.
///
/// Отличие от карточки человека в акценте: у проекта главное не история,
/// а незакрытые дела. Поэтому они идут первыми, а выполненное сворачивается.
struct ProjectDetailView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(DeletionService.self) private var deletion: DeletionService?

    let project: Project

    @State private var isEditing = false
    @State private var draftName = ""
    @State private var isShowingCompleted = false
    @State private var isConfirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                header

                if !openTasks.isEmpty || !openReminders.isEmpty {
                    section("Открытые дела") {
                        ForEach(openReminders) { ParsedEntityRow(kind: .reminder($0)) }
                        ForEach(openTasks) { ParsedEntityRow(kind: .task($0)) }
                    }
                }

                if !project.expenses.isEmpty {
                    expensesSection
                }

                if !project.notes.isEmpty {
                    section("Заметки") {
                        ForEach(project.notes.sorted { $0.createdAt > $1.createdAt }) {
                            ParsedEntityRow(kind: .note($0))
                        }
                    }
                }

                if completedCount > 0 {
                    completedSection
                }

                if project.itemsCount == 0 {
                    EmptyStateView(
                        symbol: "folder",
                        title: "Проект пуст",
                        message: "Скажите что-нибудь с названием проекта, и запись свяжется с ним сама."
                    )
                }
            }
            .padding(DS.Spacing.md)
            .padding(.bottom, DS.Spacing.lg)
        }
        .background(DS.Palette.background)
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        draftName = project.name
                        isEditing = true
                    } label: {
                        Label("Переименовать", systemImage: "pencil")
                    }

                    Button {
                        project.isArchived.toggle()
                        project.updatedAt = .now
                        try? modelContext.save()
                    } label: {
                        Label(
                            project.isArchived ? "Вернуть из архива" : "В архив",
                            systemImage: project.isArchived ? "tray.and.arrow.up" : "archivebox"
                        )
                    }

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Удалить проект", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Действия с проектом")
            }
        }
        .alert("Название проекта", isPresented: $isEditing) {
            TextField("Название", text: $draftName)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить") { rename() }
                // Кнопка была активна всегда, и на коротком имени
                // сохранение молча не срабатывало: человек видел, что
                // алерт закрылся, и считал, что переименовал.
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
        } message: {
            Text("Не короче двух символов. Прежнее название останется как синоним, чтобы старые записи не потерялись.")
        }
        .confirmationDialog(
            "Удалить проект?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) { deleteProject() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Записи останутся на месте, исчезнет только связь с проектом.")
        }
    }

    // MARK: Шапка

    private var header: some View {
        SurfaceCard {
            HStack(spacing: DS.Spacing.md) {
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(Color(projectHex: project.colorHex))
                    .frame(width: 8, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Palette.textPrimary)

                    Text(ContextView.recordsText(project.itemsCount))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)

                    if project.isArchived {
                        Label("В архиве", systemImage: "archivebox")
                            .font(DS.Font.micro)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Траты

    private var expensesSection: some View {
        let sorted = project.expenses.sorted { $0.spentAt > $1.spentAt }
        let currency = sorted.first?.currencyCode ?? "RUB"
        let total = sorted
            .filter { $0.currencyCode == currency }
            .reduce(into: Decimal(0)) { $0 += $1.amount }

        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                SectionLabel(text: "Потрачено")
                Spacer()
                Text(total.formatted(.currency(code: currency)))
                    .font(DS.Font.amount)
                    .foregroundStyle(DS.EntityColor.expense)
            }

            SurfaceCard {
                VStack(spacing: DS.Spacing.xxs) {
                    ForEach(sorted) { ParsedEntityRow(kind: .expense($0)) }
                }
            }
        }
    }

    // MARK: Выполненное

    /// Закрытые дела свёрнуты: они нужны для памяти, но не должны
    /// оттеснять то, что ещё предстоит сделать.
    private var completedSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Button {
                withAnimation(DS.Motion.enter) { isShowingCompleted.toggle() }
            } label: {
                HStack {
                    SectionLabel(text: "Выполнено (\(completedCount))")
                    Spacer()
                    Image(systemName: isShowingCompleted ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if isShowingCompleted {
                SurfaceCard {
                    VStack(spacing: DS.Spacing.xxs) {
                        ForEach(completedTasks) { ParsedEntityRow(kind: .task($0)) }
                        ForEach(completedReminders) { ParsedEntityRow(kind: .reminder($0)) }
                    }
                }
            }
        }
    }

    // MARK: Данные

    private var openTasks: [TaskItem] {
        project.tasks
            .filter { !$0.isCompleted }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var openReminders: [Reminder] {
        project.reminders.filter { !$0.isCompleted }.sorted { $0.fireDate < $1.fireDate }
    }

    private var completedTasks: [TaskItem] {
        project.tasks.filter(\.isCompleted)
    }

    private var completedReminders: [Reminder] {
        project.reminders.filter(\.isCompleted)
    }

    private var completedCount: Int {
        completedTasks.count + completedReminders.count
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let body = content()

        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: title)
            SurfaceCard {
                VStack(spacing: DS.Spacing.xxs) { body }
            }
        }
    }

    // MARK: Действия

    private func rename() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2, name != project.name else { return }

        // Прежнее название уходит в синонимы: записи, где оно уже звучало,
        // должны продолжать связываться с проектом.
        if !project.aliases.contains(project.name) {
            project.aliases.append(project.name)
        }
        project.name = name
        project.normalizedName = Project.normalize(name)
        project.updatedAt = .now
        project.syncState = .pendingUpload

        try? modelContext.save()
    }

    /// Удаление проекта не трогает записи: человек убирает папку,
    /// а не выбрасывает всё, что в ней лежало.
    private func deleteProject() {
        if let deletion {
            deletion.delete(project)
        } else {
            modelContext.delete(project)
            try? modelContext.save()
        }
        dismiss()
    }
}
