import SwiftUI

/// Строка созданной сущности: значок типа, суть и ключевое значение.
///
/// Один компонент на все четыре типа: они различаются только правой
/// колонкой, и разводить четыре почти одинаковых представления незачем.
struct ParsedEntityRow: View {

    enum Kind {
        case note(Note)
        case task(TaskItem)
        case reminder(Reminder)
        case expense(Expense)
    }

    let kind: Kind

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(tint)
            }

            if needsReview {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Требует проверки")
            }
        }
    }

    // MARK: Содержимое по типу

    private var symbolName: String {
        switch kind {
        case .note: return "note.text"
        case .task: return "checklist"
        case .reminder: return "bell"
        case .expense(let expense): return expense.category.symbolName
        }
    }

    private var tint: Color {
        switch kind {
        case .note: return .gray
        case .task: return .blue
        case .reminder: return .orange
        case .expense: return .green
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
            return note.tags.isEmpty ? nil : note.tags.joined(separator: ", ")
        case .task(let task):
            guard let dueDate = task.dueDate else { return "Задача" }
            return "До " + dueDate.formatted(date: .abbreviated, time: .omitted)
        case .reminder(let reminder):
            return reminder.fireDate.formatted(date: .abbreviated, time: .shortened)
        case .expense(let expense):
            return expense.category.displayName
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

/// Список сущностей, порождённых одним захватом.
struct ParsedItemsSection: View {

    let capture: CaptureItem

    var body: some View {
        if capture.hasDerivedItems {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(capture.expenses) { expense in
                    ParsedEntityRow(kind: .expense(expense))
                }
                ForEach(capture.reminders) { reminder in
                    ParsedEntityRow(kind: .reminder(reminder))
                }
                ForEach(capture.tasks) { task in
                    ParsedEntityRow(kind: .task(task))
                }
                ForEach(capture.notes) { note in
                    ParsedEntityRow(kind: .note(note))
                }
            }
        }
    }
}
