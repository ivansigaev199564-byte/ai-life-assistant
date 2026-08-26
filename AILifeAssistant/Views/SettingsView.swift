import SwiftData
import SwiftUI

/// Настройки: движок распознавания, язык, поведение записи и диагностика.
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.capabilities) private var capabilities
    @Environment(AppSettings.self) private var settings
    @Environment(PermissionsManager.self) private var permissions

    @State private var isPreparingWhisper = false
    @State private var whisperError: String?
    @State private var recordingsSize: Int64 = 0

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                permissionsSection

                Section("Распознавание") {
                    Picker("Движок", selection: $settings.enginePreference) {
                        ForEach(SpeechEnginePreference.allCases, id: \.self) { preference in
                            Text(preference.displayName).tag(preference)
                        }
                    }

                    Text(settings.enginePreference.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if settings.enginePreference == .whisperKit {
                        whisperStatusRow
                    }

                    Picker("Язык", selection: localeBinding) {
                        Text("Как в системе").tag(String?.none)
                        ForEach(SpeechEngineFactory.availableLocales, id: \.identifier) { locale in
                            Text(displayName(for: locale)).tag(String?.some(locale.identifier))
                        }
                    }
                    .disabled(settings.enginePreference == .whisperKit)

                    if settings.enginePreference == .whisperKit {
                        Text("WhisperKit определяет язык сам, выбор не требуется.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Запись") {
                    Toggle("Режим длинной надиктовки", isOn: $settings.isDictationMode)
                    Text(settings.isDictationMode
                         ? "Пауза до остановки: 2,5 секунды, лимит 5 минут."
                         : "Пауза до остановки: 1,4 секунды, лимит 60 секунд.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("Хранить аудио", isOn: $settings.keepAudioRecordings)
                    Text("Записи удаляются автоматически через \(RecordingStore.retentionDays) дней. Занято: \(formattedSize).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("Тактильный отклик", isOn: $settings.hapticsEnabled)
                }

                Section("Устройство") {
                    LabeledContent("Кнопка действия", value: capabilities.device.hasActionButton ? "есть" : "нет")
                    LabeledContent("Динамический остров", value: capabilities.device.hasDynamicIsland ? "есть" : "нет")
                    LabeledContent("Разбор на устройстве", value: parsingDescription)
                    LabeledContent("Модель", value: capabilities.device.modelIdentifier)
                }

                Section {
                    Button("Удалить все аудиозаписи", role: .destructive) {
                        RecordingStore().deleteAll()
                        refreshSize()
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .task { refreshSize() }
        }
    }

    // MARK: Секции

    private var permissionsSection: some View {
        Section("Разрешения") {
            LabeledContent("Микрофон", value: statusText(permissions.microphone))
            LabeledContent("Распознавание речи", value: statusText(permissions.speechRecognition))

            if permissions.requiresSystemSettings {
                Button("Открыть системные настройки") {
                    permissions.openSystemSettings()
                }
            } else if !permissions.isReadyForCapture {
                Button("Запросить разрешения") {
                    Task { await permissions.requestAll() }
                }
            }
        }
    }

    @ViewBuilder
    private var whisperStatusRow: some View {
        if isPreparingWhisper {
            HStack {
                ProgressView().controlSize(.small)
                Text("Загружаю модель")
                    .foregroundStyle(.secondary)
            }
        } else if WhisperKitRecognizer.isModelReady {
            Label("Модель загружена", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button("Загрузить модель") {
                    downloadWhisperModel()
                }
                if let whisperError {
                    Text(whisperError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text("Модель весит несколько сотен мегабайт, качайте по Wi-Fi.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Вспомогательное

    private var localeBinding: Binding<String?> {
        Binding(
            get: { settings.localeIdentifier },
            set: { settings.localeIdentifier = $0 }
        )
    }

    private var parsingDescription: String {
        switch capabilities.onDeviceParsing {
        case .foundationModels: return "Foundation Models"
        case .heuristics: return "правила и NaturalLanguage"
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: recordingsSize, countStyle: .file)
    }

    private func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private func statusText(_ status: PermissionsManager.Status) -> String {
        switch status {
        case .granted: return "разрешено"
        case .denied: return "запрещено"
        case .restricted: return "ограничено"
        case .notDetermined: return "не запрошено"
        }
    }

    private func refreshSize() {
        recordingsSize = RecordingStore().totalSize()
    }

    private func downloadWhisperModel() {
        isPreparingWhisper = true
        whisperError = nil

        Task {
            do {
                try await WhisperKitRecognizer().prepare()
            } catch {
                whisperError = error.localizedDescription
            }
            isPreparingWhisper = false
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppSettings(defaults: .standard))
        .environment(PermissionsManager())
}
