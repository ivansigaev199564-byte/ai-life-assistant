import SwiftData
import SwiftUI

/// Экран одного захвата: что было сказано, что из этого поняли
/// и что в итоге создано.
///
/// Нужен, когда разбор ошибся: пользователь видит исходный текст рядом
/// с результатом и может отправить фразу на повторный разбор.
struct CaptureDetailView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let capture: CaptureItem
    let processingQueue: ProcessingQueue

    @State private var isEditingText = false
    @State private var draftText = ""

    var body: some View {
        List {
            Section("Сказано") {
                Text(capture.text)
                    .font(.body)
                    .textSelection(.enabled)

                Button("Исправить текст") {
                    draftText = capture.text
                    isEditingText = true
                }
                .font(.subheadline)
            }

            Section("Разбор") {
                LabeledContent("Статус", value: statusText)

                if let engine = capture.parsingEngine {
                    LabeledContent("Движок", value: engineName(engine))
                }

                if capture.parseConfidence > 0 {
                    LabeledContent(
                        "Уверенность",
                        value: "\(Int(capture.parseConfidence * 100)) %"
                    )
                }

                if let parsedAt = capture.parsedAt {
                    LabeledContent(
                        "Разобрано",
                        value: parsedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }

                if let failureReason = capture.failureReason {
                    Text(failureReason)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button("Разобрать заново") {
                    Task { await processingQueue.retry(capture) }
                }
            }

            if capture.hasDerivedItems {
                Section("Создано") {
                    ParsedItemsSection(capture: capture)
                }
            } else if capture.status == .synced {
                Section("Создано") {
                    Text("Разбор не создал записей")
                        .foregroundStyle(.secondary)
                }
            }

            if capture.needsReview {
                Section {
                    Label(
                        "Смысл понят неуверенно, стоит проверить результат",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.subheadline)
                }
            }

            Section("Запись") {
                LabeledContent("Источник", value: sourceText)
                if capture.audioDuration > 0 {
                    LabeledContent(
                        "Длительность",
                        value: String(format: "%.1f с", capture.audioDuration)
                    )
                }
                if capture.recognitionConfidence > 0 {
                    LabeledContent(
                        "Распознавание",
                        value: "\(Int(capture.recognitionConfidence * 100)) %"
                    )
                }
                if let languageCode = capture.languageCode {
                    LabeledContent("Язык", value: languageCode)
                }
            }
        }
        .navigationTitle("Запись")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Исправить текст", isPresented: $isEditingText) {
            TextField("Текст записи", text: $draftText)
            Button("Отмена", role: .cancel) {}
            Button("Разобрать заново") {
                applyEditedText()
            }
        } message: {
            Text("После исправления запись будет разобрана заново.")
        }
    }

    // MARK: Действия

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
