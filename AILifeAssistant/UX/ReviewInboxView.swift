import SwiftData
import SwiftUI

/// Записи, которые приложение поняло неуверенно.
///
/// Отдельный экран, а не пометка в общей ленте: у этих записей другая
/// задача. В ленте человек просматривает прошлое, здесь разбирает
/// накопившиеся сомнения приложения, и смешивать эти два занятия значит
/// мешать обоим.
struct ReviewInboxView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let processingQueue: ProcessingQueue

    @Query(sort: \CaptureItem.createdAt, order: .reverse)
    private var captures: [CaptureItem]

    /// Записи с низкой уверенностью разбора или с заметками на проверку.
    private var needingReview: [CaptureItem] {
        captures.filter { capture in
            capture.needsReview || capture.notes.contains(where: \.needsReview)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if needingReview.isEmpty {
                    EmptyStateView(
                        symbol: "checkmark.seal",
                        title: "Всё разобрано",
                        message: "Записи, в которых приложение засомневалось, появятся здесь."
                    )
                    .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    list
                }
            }
            .background(DS.Palette.background)
            .navigationTitle("На проверку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("Приложение не уверено, что поняло эти записи правильно. Проверьте и поправьте, если нужно.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Spacing.xxs)

                ForEach(needingReview) { capture in
                    NavigationLink {
                        CaptureDetailView(capture: capture, processingQueue: processingQueue)
                    } label: {
                        reviewRow(capture)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DS.Spacing.md)
        }
    }

    private func reviewRow(_ capture: CaptureItem) -> some View {
        SurfaceCard(isHighlighted: true) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(capture.previewText)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DS.Spacing.xs) {
                    Label(
                        "уверенность \(Int(capture.parseConfidence * 100)) %",
                        systemImage: "questionmark.circle"
                    )
                    .font(DS.Font.micro)
                    .foregroundStyle(DS.Palette.warning)

                    Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(DS.Font.micro)
                        .foregroundStyle(DS.Palette.textTertiary)

                    Spacer(minLength: 0)
                }

                if capture.hasDerivedItems {
                    ParsedItemsSection(capture: capture)
                }

                // Быстрое решение прямо здесь: чаще всего разбор верный,
                // и человеку достаточно подтвердить, не открывая запись.
                HStack(spacing: DS.Spacing.xs) {
                    Button {
                        confirm(capture)
                    } label: {
                        Label("Всё верно", systemImage: "checkmark")
                            .font(DS.Font.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(DS.Palette.success)

                    Button {
                        Task { await processingQueue.retry(capture) }
                    } label: {
                        Label("Разобрать заново", systemImage: "arrow.clockwise")
                            .font(DS.Font.caption)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, DS.Spacing.xxs)
            }
        }
    }

    /// Подтверждение снимает пометку и поднимает уверенность до полной:
    /// человек посмотрел и согласился, это надёжнее любого разбора.
    private func confirm(_ capture: CaptureItem) {
        capture.parseConfidence = 1
        capture.notes.forEach { note in
            note.needsReview = false
            note.tags.removeAll { $0 == EntityMaterializer.reviewTag }
            note.syncState = .pendingUpload
        }
        capture.tasks.forEach { $0.needsReview = false }
        capture.reminders.forEach { $0.needsReview = false }
        capture.expenses.forEach { $0.needsReview = false }
        capture.updatedAt = .now

        try? modelContext.save()
    }
}
