import SwiftUI

/// Подробная строка созданной сущности для экрана записи.
///
/// В ленте те же сущности показываются компактными плашками, здесь нужен
/// полный вид: суть, время, сумма и пометка о проверке.
///
/// У задач и напоминаний строка ещё и работает: слева стоит настоящая
/// галочка. Дело, которое нельзя закрыть там, где оно показано, превращает
/// список дел в список сожалений.
struct ParsedEntityRow: View {

    enum Kind {
        case note(Note)
        case task(TaskItem)
        case reminder(Reminder)
        case expense(Expense)
    }

    let kind: Kind

    /// Отсутствует в предпросмотре и в тех местах, где сервис не пробрасывался:
    /// строка тогда просто не реагирует на нажатие, а не падает.
    @Environment(CompletionService.self) private var completion: CompletionService?

    var body: some View {
        if isCompletable {
            row.contextMenu {
                Button {
                    toggleCompletion()
                } label: {
                    Label(
                        isCompleted ? "Вернуть в работу" : "Готово",
                        systemImage: isCompleted ? "arrow.uturn.backward" : "checkmark"
                    )
                }
            }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: DS.Spacing.xxs) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.entityTitle)
                    .foregroundStyle(isCompleted ? DS.Palette.textTertiary : DS.Palette.textPrimary)
                    .strikethrough(isCompleted, color: DS.Palette.textTertiary)
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(DS.Font.micro)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }

            Spacer(minLength: DS.Spacing.xs)

            if let trailing {
                Text(trailing)
                    .font(DS.Font.amount)
                    .foregroundStyle(tint)
            }

            if needsReview {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Palette.warning)
                    .accessibilityLabel("Требует проверки")
            }
        }
        .animation(DS.Motion.enter, value: isCompleted)
    }

    // MARK: Значок

    /// Область нажатия всегда 44 на 44, даже когда значок ни на что не
    /// реагирует: иначе строки разных типов разъезжаются по левому краю.
    @ViewBuilder
    private var leadingIcon: some View {
        if isCompletable {
            Button {
                toggleCompletion()
            } label: {
                iconBadge
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCompleted ? "Снять отметку выполнения" : "Отметить выполненным")
            .accessibilityValue(isCompleted ? "выполнено" : "не выполнено")
        } else {
            iconBadge
        }
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(tint.opacity(isCompleted ? 0.08 : 0.14))
                .frame(width: 34, height: 34)

            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isCompleted ? DS.Palette.textTertiary : tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    // MARK: Отметка выполнения

    private var isCompletable: Bool {
        switch kind {
        case .task, .reminder: return true
        case .note, .expense: return false
        }
    }

    private var isCompleted: Bool {
        switch kind {
        case .task(let task): return task.isCompleted
        case .reminder(let reminder): return reminder.isCompleted
        case .note, .expense: return false
        }
    }

    private func toggleCompletion() {
        switch kind {
        case .task(let task): completion?.toggle(task)
        case .reminder(let reminder): completion?.toggle(reminder)
        case .note, .expense: break
        }
    }

    // MARK: Содержимое по типу

    private var tint: Color {
        switch kind {
        case .note: return DS.EntityColor.note
        case .task: return DS.EntityColor.task
        case .reminder: return DS.EntityColor.reminder
        case .expense: return DS.EntityColor.expense
        }
    }

    private var symbolName: String {
        switch kind {
        case .note: return "text.alignleft"
        case .task(let task): return task.isCompleted ? "checkmark.circle.fill" : "circle"
        case .reminder(let reminder): return reminder.isCompleted ? "checkmark.circle.fill" : "bell.fill"
        case .expense(let expense): return expense.category.symbolName
        }
    }

    private var title: String {
        switch kind {
        case .note(let note): return note.displayTitle
        case .task(let task): return task.title
        case .reminder(let reminder): return reminder.title
        case .expense(let expense):
            return expense.details.isEmpty ? expense.category.displayName : expense.details
        }
    }

    private var subtitle: String? {
        switch kind {
        case .note(let note):
            return note.tags.isEmpty ? "Заметка" : note.tags.joined(separator: ", ")
        case .task(let task):
            guard let dueDate = task.dueDate else { return "Задача" }
            return "До " + dueDate.formatted(date: .abbreviated, time: .omitted)
        case .reminder(let reminder):
            return reminder.fireDate.formatted(date: .abbreviated, time: .shortened)
        case .expense(let expense):
            return expense.merchant ?? expense.category.displayName
        }
    }

    /// Сумма справа. Слово «готово» отсюда убрано: состояние теперь видно
    /// по галочке и зачёркнутому заголовку, а VoiceOver читает его значением.
    private var trailing: String? {
        switch kind {
        case .expense(let expense): return expense.formattedAmount
        case .note, .task, .reminder: return nil
        }
    }

    private var needsReview: Bool {
        switch kind {
        case .note(let note): return note.needsReview
        case .task(let task): return task.needsReview
        case .reminder(let reminder): return reminder.needsReview
        case .expense(let expense): return expense.needsReview
        }
    }
}

/// Все сущности, порождённые одним захватом.
///
/// Порядок фиксирован по важности: деньги, время, действия, мысли.
/// Он не меняется от записи к записи, поэтому глаз находит нужное
/// на одном и том же месте.
struct ParsedItemsSection: View {

    let capture: CaptureItem

    var body: some View {
        if capture.hasDerivedItems {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                ForEach(capture.expenses) { ParsedEntityRow(kind: .expense($0)) }
                ForEach(capture.reminders) { ParsedEntityRow(kind: .reminder($0)) }
                ForEach(capture.tasks) { ParsedEntityRow(kind: .task($0)) }
                ForEach(capture.notes) { ParsedEntityRow(kind: .note($0)) }
            }
        }
    }
}
