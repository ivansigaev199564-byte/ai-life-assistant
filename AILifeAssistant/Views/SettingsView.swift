import SwiftData
import SwiftUI

/// Настройки: распознавание, поведение записи, диагностика устройства.
///
/// Раздел «Устройство» стоит здесь не для красоты: он честно отвечает
/// на вопрос, почему у одного пользователя разбор идёт на устройстве,
/// а у другого нет.
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
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    permissionsSection
                    recognitionSection(settings: settings)
                    captureSection(settings: settings)
                    deviceSection
                    dataSection
                }
                .padding(DS.Spacing.md)
                .padding(.bottom, DS.Spacing.lg)
            }
            .background(DS.Palette.background)
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task { refreshSize() }
        }
    }

    // MARK: Разрешения

    private var permissionsSection: some View {
        section("Разрешения") {
            permissionRow("Микрофон", permissions.microphone)
            permissionRow("Распознавание речи", permissions.speechRecognition)

            if permissions.requiresSystemSettings {
                Button("Открыть системные настройки") {
                    permissions.openSystemSettings()
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.accent)
            } else if !permissions.isReadyForCapture {
                Button("Запросить разрешения") {
                    Task { await permissions.requestAll() }
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.accent)
            }
        }
    }

    private func permissionRow(_ title: String, _ status: PermissionsManager.Status) -> some View {
        HStack {
            Text(title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
            Spacer()
            HStack(spacing: DS.Spacing.xxs) {
                Circle()
                    .fill(status == .granted ? DS.Palette.success : DS.Palette.danger)
                    .frame(width: 6, height: 6)
                Text(statusText(status))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textPrimary)
            }
        }
    }

    // MARK: Распознавание

    private func recognitionSection(settings: AppSettings) -> some View {
        section("Распознавание") {
            // Сегменты вместо выпадающего списка: вариантов три,
            // и все должны быть видны сразу.
            Picker("Движок", selection: Binding(
                get: { settings.enginePreference },
                set: { settings.enginePreference = $0 }
            )) {
                ForEach(SpeechEnginePreference.allCases, id: \.self) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.enginePreference.explanation)
                .font(DS.Font.micro)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.enginePreference == .whisperKit {
                whisperStatus
            } else {
                Picker("Язык", selection: Binding(
                    get: { settings.localeIdentifier },
                    set: { settings.localeIdentifier = $0 }
                )) {
                    Text("Как в системе").tag(String?.none)
                    ForEach(SpeechEngineFactory.availableLocales, id: \.identifier) { locale in
                        Text(displayName(for: locale)).tag(String?.some(locale.identifier))
                    }
                }
                .font(DS.Font.caption)
                .tint(DS.Palette.accent)
            }
        }
    }

    @ViewBuilder
    private var whisperStatus: some View {
        if isPreparingWhisper {
            HStack(spacing: DS.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Загружаю модель")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        } else if WhisperKitRecognizer.isModelReady {
            Label("Модель загружена", systemImage: "checkmark.circle.fill")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.success)
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Button("Загрузить модель") { downloadWhisperModel() }
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.accent)

                if let whisperError {
                    Text(whisperError)
                        .font(DS.Font.micro)
                        .foregroundStyle(DS.Palette.danger)
                }

                Text("Модель весит несколько сотен мегабайт, качайте по Wi-Fi.")
                    .font(DS.Font.micro)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    // MARK: Запись

    private func captureSection(settings: AppSettings) -> some View {
        section("Запись") {
            toggleRow(
                "Режим длинной надиктовки",
                hint: settings.isDictationMode
                    ? "Пауза до остановки 2,5 секунды, лимит 5 минут"
                    : "Пауза до остановки 1,4 секунды, лимит 60 секунд",
                isOn: Binding(
                    get: { settings.isDictationMode },
                    set: { settings.isDictationMode = $0 }
                )
            )

            toggleRow(
                "Хранить аудио",
                hint: "Записи удаляются через \(RecordingStore.retentionDays) дней. Занято: \(formattedSize)",
                isOn: Binding(
                    get: { settings.keepAudioRecordings },
                    set: { settings.keepAudioRecordings = $0 }
                )
            )

            toggleRow(
                "Тактильный отклик",
                hint: nil,
                isOn: Binding(
                    get: { settings.hapticsEnabled },
                    set: { settings.hapticsEnabled = $0 }
                )
            )
        }
    }

    private func toggleRow(_ title: String, hint: String?, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(DS.Font.entityTitle)
                    .foregroundStyle(DS.Palette.textPrimary)
            }
            .tint(DS.Palette.accent)

            if let hint {
                Text(hint)
                    .font(DS.Font.micro)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    // MARK: Устройство

    private var deviceSection: some View {
        section("Устройство") {
            capabilityRow("Кнопка действия", capabilities.device.hasActionButton)
            capabilityRow("Динамический остров", capabilities.device.hasDynamicIsland)
            capabilityRow("Разбор на устройстве", capabilities.hasFoundationModels)

            HStack {
                Text("Модель")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                Text(capabilities.device.modelIdentifier)
                    .font(DS.Font.micro)
                    .foregroundStyle(DS.Palette.textTertiary)
            }

            if !capabilities.hasFoundationModels {
                Text("Локальная модель доступна на iPhone 15 Pro и новее с iOS 26. Без неё разбор идёт по правилам.")
                    .font(DS.Font.micro)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func capabilityRow(_ title: String, _ available: Bool) -> some View {
        HStack {
            Text(title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
            Spacer()
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 14))
                .foregroundStyle(available ? DS.Palette.success : DS.Palette.textTertiary)
        }
    }

    // MARK: Данные

    private var dataSection: some View {
        section("Данные") {
            Text("Записи и разбор хранятся только на устройстве.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)

            Button(role: .destructive) {
                RecordingStore().deleteAll()
                refreshSize()
            } label: {
                Label("Удалить все аудиозаписи", systemImage: "trash")
                    .font(DS.Font.caption)
            }
            .foregroundStyle(DS.Palette.danger)
        }
    }

    // MARK: Каркас секции

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: title)
            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    content()
                }
            }
        }
    }

    // MARK: Вспомогательное

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
