import SwiftUI

/// Строка записи в ленте.
///
/// Иерархия жёсткая: сначала то, что человек сказал, затем то, что из этого
/// получилось, и только потом служебные метки. Разбор показывается плашками,
/// потому что по цвету тип читается быстрее, чем по тексту.
struct CaptureRowView: View {

    let capture: CaptureItem

    var body: some View {
        SurfaceCard(padding: DS.Spacing.sm + 2, isHighlighted: capture.needsReview) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                header
                entities
                footer
            }
        }
    }

    // MARK: Сказанное

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.xs) {
            StatusBadge(status: capture.status)
                .padding(.top, 5)

            Text(capture.previewText)
                .font(DS.Font.body)
                .foregroundStyle(
                    capture.status == .failed ? DS.Palette.textSecondary : DS.Palette.textPrimary
                )
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Что создано

    @ViewBuilder
    private var entities: some View {
        if capture.hasDerivedItems {
            // Плашки переносятся по строкам: одна фраза может дать
            // и трату, и напоминание, и заметку сразу.
            FlowLayout(spacing: DS.Spacing.xxs + 2) {
                ForEach(capture.expenses) { expense in
                    EntityChip(
                        kind: .expense,
                        title: expense.details.isEmpty
                            ? expense.category.displayName
                            : expense.details,
                        value: expense.formattedAmount,
                        needsReview: expense.needsReview
                    )
                }
                ForEach(capture.reminders) { reminder in
                    EntityChip(
                        kind: .reminder,
                        title: reminder.title,
                        value: Self.shortTime(reminder.fireDate),
                        needsReview: reminder.needsReview
                    )
                }
                ForEach(capture.tasks) { task in
                    EntityChip(kind: .task, title: task.title, needsReview: task.needsReview)
                }
                ForEach(capture.notes) { note in
                    EntityChip(kind: .note, title: note.displayTitle, needsReview: note.needsReview)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: Служебное

    private var footer: some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(capture.createdAt.formatted(date: .omitted, time: .shortened))

            if capture.audioDuration > 0 {
                Label(
                    Self.durationText(capture.audioDuration),
                    systemImage: "waveform"
                )
                .labelStyle(.titleAndIcon)
            }

            if capture.status == .processing {
                Text("разбираю")
                    .foregroundStyle(DS.Palette.accent)
            }

            if let failureReason = capture.failureReason, capture.status == .failed {
                Text(failureReason)
                    .foregroundStyle(DS.Palette.danger)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .font(DS.Font.micro)
        .foregroundStyle(DS.Palette.textTertiary)
    }

    // MARK: Форматирование

    private static func shortTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInTomorrow(date) {
            return "завтра " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) с" }
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// Раскладка с переносом по строкам.
///
/// В SwiftUI нет готового аналога, а плашки сущностей обязаны переноситься:
/// одна фраза даёт от одной до четырёх штук разной ширины.
struct FlowLayout: Layout {

    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > maxWidth, lineWidth > 0 {
                height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: maxWidth, height: height + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )

            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
