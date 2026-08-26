import SwiftData
import SwiftUI

/// Всё, что связано с человеком.
///
/// Отвечает на вопрос, который иначе требует перебора всей ленты:
/// что у меня вообще с этим человеком. Долги, обещания, встречи
/// и совместные траты собраны в одном месте.
struct PersonDetailView: View {

    @Environment(\.modelContext) private var modelContext

    let person: Person

    @State private var isEditingName = false
    @State private var draftName = ""

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
                Button {
                    draftName = person.name
                    isEditingName = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Переименовать")
            }
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
