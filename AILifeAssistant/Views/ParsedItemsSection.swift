import SwiftUI

/// Подробная строка созданной сущности для экрана записи.
///
/// В ленте те же сущности показываются компактными плашками, здесь нужен
/// полный вид: суть, время, сумма и пометка о проверке.
struct ParsedEntityRow: View {

    enum Kind {
        case note(Note)
        case task(TaskItem)
        case reminder(Reminder)
        case expense(Expense)
    }

    let kind: Kind

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)

                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.entityTitle)
                    .foregroundStyle(DS.Palette.textPrimary)
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
        .padding(.vertical, DS.Spacing.xxs)
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
        case .task: return "checkmark.circle.fill"
        case .reminder: return "bell.fill"
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

    private var trailing: String? {
        switch kind {
        case .expense(let expense): return expense.formattedAmount
        case .task(let task): return task.isCompleted ? "готово" : nil
        case .reminder(let reminder): return reminder.isCompleted ? "готово" : nil
        case .note: return nil
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
