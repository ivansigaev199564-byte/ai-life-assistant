import SwiftData
import SwiftUI

/// Всё, что связано с человеком.
///
/// Отвечает на вопрос, который иначе требует перебора всей ленты:
/// что у меня вообще с этим человеком. Долги, обещания, встречи
/// и совместные траты собраны в одном месте.
struct PersonDetailView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(DeletionService.self) private var deletion: DeletionService?

    let person: Person

    /// Все люди: нужны для объединения дублей, которые приложение
    /// заводит само из речи.
    @Query(sort: \Person.name) private var people: [Person]

    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var isConfirmingDelete = false
    @State private var isChoosingMerge = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                header

                if !person.reminders.isEmpty {
                    section("Напоминания") {
                        ForEach(person.reminders.sorted { $0.fireDate < $1.fireDate }) { reminder in
                            ParsedEntityRow(kind: .reminder(reminder))
                        }
                    }
                }

                if !person.tasks.isEmpty {
                    section("Задачи") {
                        ForEach(person.tasks.sorted { !$0.isCompleted && $1.isCompleted }) { task in
                            ParsedEntityRow(kind: .task(task))
                        }
                    }
                }

                if !person.expenses.isEmpty {
                    expensesSection
                }

                if !person.notes.isEmpty {
                    section("Заметки") {
                        ForEach(person.notes.sorted { $0.createdAt > $1.createdAt }) { note in
                            ParsedEntityRow(kind: .note(note))
                        }
                    }
                }

                if person.totalMentions == 0 {
                    EmptyStateView(
                        symbol: "tray",
                        title: "Пока пусто",
                        message: "Записи с упоминанием этого человека появятся здесь."
                    )
                }
            }
            .padding(DS.Spacing.md)
            .padding(.bottom, DS.Spacing.lg)
        }
        .background(DS.Palette.background)
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        draftName = person.name
                        isEditingName = true
                    } label: {
                        Label("Переименовать", systemImage: "pencil")
                    }

                    // Карточки заводятся автоматически из речи, поэтому
                    // дубли неизбежны: «Миша» и «Михаил» это один человек.
                    if mergeCandidates.count > 0 {
                        Button {
                            isChoosingMerge = true
                        } label: {
                            Label("Объединить с…", systemImage: "arrow.triangle.merge")
                        }
                    }

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Действия с человеком")
            }
        }
        .confirmationDialog(
            "Удалить человека?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) { deletePerson() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Записи останутся на месте, исчезнет только карточка и связи с ней.")
        }
        .confirmationDialog(
            "С кем объединить?",
            isPresented: $isChoosingMerge,
            titleVisibility: .visible
        ) {
            ForEach(mergeCandidates) { candidate in
                Button(candidate.name) { merge(into: candidate) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Записи и упоминания перейдут выбранному человеку, а это имя останется у него синонимом.")
        }
        .alert("Имя человека", isPresented: $isEditingName) {
            TextField("Имя", text: $draftName)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить") { renamePerson() }
        } message: {
            Text("Прежнее написание останется как синоним, чтобы старые записи не потерялись.")
        }
    }

    // MARK: Шапка

    private var header: some View {
        SurfaceCard {
            HStack(spacing: DS.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(DS.Palette.accent.opacity(0.15))
                        .frame(width: 56, height: 56)

                    Text(String(person.name.prefix(1)).uppercased())
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Palette.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(person.name)
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Palette.textPrimary)

                    Text(ContextView.recordsText(person.totalMentions))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)

                    // Синонимы показывают, в каких формах имя встречалось
                    // в речи: так видно, почему разные фразы попали к одному
                    // человеку.
                    if !person.aliases.isEmpty {
                        Text("также: " + person.aliases.joined(separator: ", "))
                            .font(DS.Font.micro)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Траты

    /// У трат, в отличие от прочего, есть сумма, и первое, что хочется
    /// знать про человека, это сколько на него ушло.
    private var expensesSection: some View {
        let sorted = person.expenses.sorted { $0.spentAt > $1.spentAt }
        let currency = sorted.first?.currencyCode ?? "RUB"
        let total = sorted
            .filter { $0.currencyCode == currency }
            .reduce(into: Decimal(0)) { $0 += $1.amount }

        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                SectionLabel(text: "Траты")
                Spacer()
                Text(total.formatted(.currency(code: currency)))
                    .font(DS.Font.amount)
                    .foregroundStyle(DS.EntityColor.expense)
            }

            SurfaceCard {
                VStack(spacing: DS.Spacing.xxs) {
                    ForEach(sorted) { expense in
                        ParsedEntityRow(kind: .expense(expense))
                    }
                }
            }
        }
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

    /// Прежнее написание уходит в синонимы: иначе старые записи перестанут
    /// находиться, а разбор заведёт нового человека при следующем упоминании.
    /// Кого предлагать для объединения: все, кроме самого себя.
    private var mergeCandidates: [Person] {
        people.filter { $0.id != person.id }
    }

    private func deletePerson() {
        if let deletion {
            deletion.delete(person)
        } else {
            modelContext.delete(person)
            try? modelContext.save()
        }
        dismiss()
    }

    /// Переносит записи этого человека выбранному и удаляет дубль.
    ///
    /// Имя уходит в синонимы: иначе следующая фраза с тем же словом
    /// заведёт дубль заново.
    private func merge(into target: Person) {
        for reminder in person.reminders where !target.reminders.contains(where: { $0.id == reminder.id }) {
            target.reminders.append(reminder)
        }
        for task in person.tasks where !target.tasks.contains(where: { $0.id == task.id }) {
            target.tasks.append(task)
        }
        for expense in person.expenses where !target.expenses.contains(where: { $0.id == expense.id }) {
            target.expenses.append(expense)
        }
        for note in person.notes where !target.notes.contains(where: { $0.id == note.id }) {
            target.notes.append(note)
        }

        for alias in person.aliases + [person.name] where !target.aliases.contains(alias) {
            target.aliases.append(alias)
        }

        target.updatedAt = .now
        target.syncState = .pendingUpload

        if let deletion {
            deletion.delete(person)
        } else {
            modelContext.delete(person)
            try? modelContext.save()
        }

        dismiss()
    }

    private func renamePerson() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2, name != person.name else { return }

        if !person.aliases.contains(person.name) {
            person.aliases.append(person.name)
        }
        person.name = name
        person.normalizedName = Person.normalize(name)
        person.updatedAt = .now
        person.syncState = .pendingUpload

        try? modelContext.save()
    }
}
