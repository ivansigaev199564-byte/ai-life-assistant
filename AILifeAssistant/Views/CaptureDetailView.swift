import SwiftData
import SwiftUI

/// Экран записи: что было сказано, что из этого поняли, что создано.
///
/// Нужен ровно в двух случаях: разбор ошибся, или пользователь хочет
/// увидеть подробности. Поэтому исходная фраза лежит сверху, а действия
/// по исправлению не спрятаны в меню.
struct CaptureDetailView: View {

    @Environment(\.modelContext) private var modelContext

    let capture: CaptureItem
    let processingQueue: ProcessingQueue

    @State private var isEditingText = false
    @State private var draftText = ""
    @State private var isReparsing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                spoken
                parsing

                if capture.hasDerivedItems {
                    created
                }

                recording
            }
            .padding(DS.Spacing.md)
            .padding(.bottom, DS.Spacing.lg)
        }
        .background(DS.Palette.background)
        .navigationTitle("Запись")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingText) { editSheet }
    }

    // MARK: Сказанное

    private var spoken: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: "Сказано")

            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text(capture.text)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        draftText = capture.text
                        isEditingText = true
                    } label: {
                        Label("Исправить текст", systemImage: "pencil")
                            .font(DS.Font.caption)
                    }
                    .foregroundStyle(DS.Palette.accent)
                }
            }
        }
    }

    // MARK: Разбор

    private var parsing: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: "Разбор")

            SurfaceCard(isHighlighted: capture.needsReview) {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    if capture.needsReview {
                        Label(
                            "Смысл понят неуверенно, стоит проверить результат",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.warning)
                    }

                    detailRow("Статус", statusText)

                    if let engine = capture.parsingEngine {
                        detailRow("Движок", engineName(engine))
                    }

                    if capture.parseConfidence > 0 {
                        confidenceRow
                    }

                    if let failureReason = capture.failureReason {
                        Text(failureReason)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Palette.danger)
                    }

                    // Кнопка молчала: нажатие ничего не показывало, а при
                    // исчерпанных попытках не делало и вовсе ничего.
                    Button {
                        isReparsing = true
                        Task {
                            await processingQueue.retry(capture)
                            isReparsing = false
                        }
                    } label: {
                        if isReparsing {
                            HStack(spacing: DS.Spacing.xs) {
                                ProgressView().controlSize(.small)
                                Text("Разбираю")
                                    .font(DS.Font.caption)
                            }
                        } else {
                            Label("Разобрать заново", systemImage: "arrow.clockwise")
                                .font(DS.Font.caption)
                        }
                    }
                    .foregroundStyle(DS.Palette.accent)
                    .disabled(isReparsing)
                }
            }
        }
    }

    /// Уверенность показана полосой: голое число ничего не говорит,
    /// а полоса сразу читается как «нормально» или «слабо».
    private var confidenceRow: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack {
                Text("Уверенность")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Text("\(Int(capture.parseConfidence * 100)) %")
                    .font(DS.Font.amount)
                    .foregroundStyle(confidenceColor)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Palette.surfaceElevated)
                    Capsule()
                        .fill(confidenceColor)
                        .frame(width: geometry.size.width * capture.parseConfidence)
                }
            }
            .frame(height: 4)
        }
    }

    private var confidenceColor: Color {
        capture.parseConfidence >= EntityMaterializer.confidenceThreshold
            ? DS.Palette.success
            : DS.Palette.warning
    }

    // MARK: Созданное

    private var created: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: "Создано")

            SurfaceCard {
                ParsedItemsSection(capture: capture)
            }
        }
    }

    // MARK: Запись

    private var recording: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: "Запись")

            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    detailRow("Источник", sourceText)

                    if capture.audioDuration > 0 {
                        detailRow("Длительность", String(format: "%.1f с", capture.audioDuration))
                    }
                    if capture.recognitionConfidence > 0 {
                        detailRow("Распознавание", "\(Int(capture.recognitionConfidence * 100)) %")
                    }
                    if let languageCode = capture.languageCode {
                        detailRow("Язык", languageCode)
                    }
                    detailRow(
                        "Создано",
                        capture.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
            Spacer()
            Text(value)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textPrimary)
        }
    }

    // MARK: Правка текста

    private var editSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                TextEditor(text: $draftText)
                    .font(DS.Font.body)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Spacing.sm)
                    .background {
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(DS.Palette.surfaceElevated)
                    }
                    .frame(minHeight: 140)

                Text("После исправления запись будет разобрана заново.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)

                Spacer()
            }
            .padding(DS.Spacing.md)
            .background(DS.Palette.background)
            .navigationTitle("Исправить текст")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { isEditingText = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Разобрать") {
                        applyEditedText()
                        isEditingText = false
                    }
                    .fontWeight(.semibold)
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Правка текста означает новый разбор: старый результат больше
    /// не соответствует сказанному.
    private func applyEditedText() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != capture.text else { return }

        capture.text = trimmed
        capture.updatedAt = .now
        capture.parsedAt = nil
        capture.parseConfidence = 0
        try? modelContext.save()

        Task { await processingQueue.retry(capture) }
    }

    // MARK: Тексты

    private var statusText: String {
        switch capture.status {
        case .pending: return "ожидает разбора"
        case .processing: return "разбирается"
        case .synced: return "разобрано"
        case .failed: return "ошибка"
        }
    }

    private var sourceText: String {
        switch capture.source {
        case .actionButton: return "кнопка действия"
        case .controlCenter: return "Пункт управления"
        case .widget: return "виджет"
        case .siri: return "Siri"
        case .inApp: return "приложение"
        case .shareExtension: return "поделиться"
        case .manualText: return "ввод текстом"
        }
    }

    private func engineName(_ engine: ParsingEngine) -> String {
        switch engine {
        case .fastPath: return "правила"
        case .foundationModels: return "локальная модель"
        case .cloud: return "облачная модель"
        case .manual: return "исправлено вручную"
        }
    }
}
