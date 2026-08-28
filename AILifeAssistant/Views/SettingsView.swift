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

    /// Системные интеграции. Опциональны, чтобы предпросмотр обходился
    /// без EventKit и центра уведомлений.
    @Environment(ReminderMirror.self) private var reminderMirror: ReminderMirror?
    @Environment(EventKitService.self) private var eventKit: EventKitService?
    @Environment(NotificationService.self) private var notifications: NotificationService?
    @Environment(AppLock.self) private var appLock: AppLock?
    @Environment(NetworkMonitor.self) private var network: NetworkMonitor?

    @State private var isPreparingWhisper = false
    @State private var whisperTask: Task<Void, Never>?
    @State private var whisperError: String?
    @State private var recordingsSize: Int64 = 0
    @State private var exportedFile: URL?
    @State private var exportError: String?

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    permissionsSection
                    recognitionSection(settings: settings)
                    captureSection(settings: settings)
                    integrationsSection
                    AccountSection()
                    securitySection
                    examplesSection
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
            .sheet(item: exportedFileBinding) { file in
                // Системный лист «Поделиться»: файл можно положить
                // в Файлы, отправить себе почтой или открыть в таблице.
                ShareSheet(url: file.url)
            }
        }
    }

    /// Обёртка для файла: sheet(item:) требует Identifiable.
    private struct ExportedFile: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var exportedFileBinding: Binding<ExportedFile?> {
        Binding(
            get: { exportedFile.map(ExportedFile.init) },
            set: { newValue in exportedFile = newValue?.url }
        )
    }

    private func export(_ format: ExportService.Format) {
        exportError = nil

        Task {
            do {
                exportedFile = try await ExportService(modelContext: modelContext).export(format)
            } catch {
                exportError = "Не удалось подготовить файл: " + error.localizedDescription
                Log.data.error("Выгрузка не удалась: \(error.localizedDescription)")
            }
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
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Загружаю модель")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }

                // Ждать сотни мегабайт без единой кнопки нельзя. Полосы
                // с процентами здесь нет намеренно: библиотека не отдаёт
                // прогресс загрузки, и рисовать выдуманный некрасиво.
                Button("Отменить") { cancelWhisperDownload() }
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.danger)
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

                // Предупреждение вместо запрета: решение всё равно за
                // человеком, но платить за сотни мегабайт вслепую он
                // не должен.
                Text(network?.isExpensive == true
                     ? "Сейчас сотовая сеть, а модель весит несколько сотен мегабайт."
                     : "Модель весит несколько сотен мегабайт, качайте по Wi-Fi.")
                    .font(DS.Font.micro)
                    .foregroundStyle(network?.isExpensive == true
                                     ? DS.Palette.warning
                                     : DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                "Шумное место",
                hint: "Улица, кафе, машина. Приложение перестанет принимать фоновый шум за речь, но говорить придётся чуть громче.",
                isOn: Binding(
                    get: { settings.isNoisyEnvironment },
                    set: { settings.isNoisyEnvironment = $0 }
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

    // MARK: Интеграции

    /// Напоминание, о котором телефон не напомнит, бесполезно. Поэтому обе
    /// строки этой секции про одно и то же: дойдёт ли сказанное до системы.
    private var integrationsSection: some View {
        section("Интеграции") {
            notificationRow

            Divider().overlay(DS.Palette.border)

            toggleRow(
                "Дублировать в Напоминания",
                hint: "Дела появятся в системном приложении Напоминания: на часах, в машине и на других устройствах. Закрытые там дела закроются и здесь.",
                isOn: mirroringBinding
            )

            if reminderMirror?.isMirroringEnabled == true, eventKit?.remindersAccess == .denied {
                Text("Доступ к Напоминаниям запрещён, дублировать некуда.")
                    .font(DS.Font.micro)
                    .foregroundStyle(DS.Palette.danger)

                Button("Открыть системные настройки") {
                    permissions.openSystemSettings()
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.accent)
            }

            if let lastSyncAt = reminderMirror?.lastSyncAt {
                Text("Последняя сверка: " + lastSyncAt.formatted(date: .omitted, time: .shortened))
                    .font(DS.Font.micro)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var notificationRow: some View {
        HStack {
            Text("Уведомления")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
            Spacer()
            HStack(spacing: DS.Spacing.xxs) {
                Circle()
                    .fill(notificationsGranted ? DS.Palette.success : DS.Palette.danger)
                    .frame(width: 6, height: 6)
                Text(notificationStatusText)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textPrimary)
            }
        }

        if notifications?.permission == .notDetermined {
            Button("Разрешить уведомления") {
                Task { await notifications?.requestPermission() }
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Palette.accent)
        } else if notifications?.permission == .denied {
            // Без уведомлений напоминание превращается в запись в блокноте:
            // приложение о нём знает, а человек нет.
            Text("Без разрешения напоминания не прозвучат.")
                .font(DS.Font.micro)
                .foregroundStyle(DS.Palette.textTertiary)

            Button("Открыть системные настройки") {
                permissions.openSystemSettings()
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Palette.accent)
        }
    }

    private var notificationsGranted: Bool {
        notifications?.permission == .granted || notifications?.permission == .provisional
    }

    private var notificationStatusText: String {
        guard let permission = notifications?.permission else { return "не запрошено" }

        switch permission {
        case .granted: return "разрешено"
        case .provisional: return "без звука"
        case .denied: return "запрещено"
        case .notDetermined: return "не запрошено"
        }
    }

    /// Включение зеркалирования это и есть повод спросить доступ: у системного
    /// окна появляется понятная причина, и человек соглашается охотнее.
    private var mirroringBinding: Binding<Bool> {
        Binding(
            get: { reminderMirror?.isMirroringEnabled ?? false },
            set: { enabled in
                guard let reminderMirror else { return }

                guard enabled else {
                    reminderMirror.setMirroring(false)
                    return
                }

                Task {
                    if let eventKit, eventKit.remindersAccess != .granted {
                        await eventKit.requestRemindersAccess()
                    }
                    reminderMirror.setMirroring(eventKit?.remindersAccess == .granted)
                }
            }
        )
    }

    // MARK: Безопасность

    /// Замок нужен ровно затем, зачем он на двери: дневник, траты и имена
    /// людей открыты любому, у кого телефон в руках разблокированным.
    @ViewBuilder
    private var securitySection: some View {
        if let appLock {
            section("Безопасность") {
                if appLock.isAvailable {
                    toggleRow(
                        "Запрашивать Face ID",
                        hint: "Через минуту в фоне приложение запирается. Записи не видны, пока вы не подтвердите, что это вы.",
                        isOn: Binding(
                            get: { appLock.isEnabled },
                            set: { appLock.isEnabled = $0 }
                        )
                    )
                } else {
                    Text("На этом устройстве нет ни Face ID, ни кода-пароля, запирать нечем.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
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

    // MARK: Что можно сказать

    /// Примеры фраз были видны один раз при первом запуске и больше
    /// никогда: человек, забывший формулировку, найти её не мог.
    private var examplesSection: some View {
        section("Что можно сказать") {
            ForEach(Self.examples, id: \.self) { example in
                Text("«" + example + "»")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Можно сказать несколько дел подряд одной фразой: приложение разложит их по отдельности.")
                .font(DS.Font.micro)
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let examples = [
        "купил кофе за 300",
        "напомни завтра в девять позвонить в банк",
        "нужно забрать посылку",
        "каждый день в полдевятого пить витамины"
    ]

    // MARK: Данные

    private var dataSection: some View {
        section("Данные") {
            Text("Записи и разбор хранятся только на устройстве.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)

            // Выгрузка стоит выше удаления не случайно: сначала человеку
            // предлагают забрать своё, и только потом стереть.
            ForEach(ExportService.Format.allCases) { format in
                Button {
                    export(format)
                } label: {
                    Label(format.title, systemImage: "square.and.arrow.up")
                        .font(DS.Font.caption)
                }
                .foregroundStyle(DS.Palette.accent)
            }

            if let exportError {
                Text(exportError)
                    .font(DS.Font.micro)
                    .foregroundStyle(DS.Palette.danger)
            }

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
        // Содержимое вычисляется здесь, а не внутри карточки: SurfaceCard
        // хранит своё замыкание, и передача туда неescaping-параметра
        // не компилируется.
        let body = content()

        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: title)
            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    body
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

    /// Размер каталога записей считается обходом файлов, а это заметная
    /// работа на диске: главный поток она держать не должна.
    private func refreshSize() {
        Task {
            recordingsSize = await Task.detached(priority: .utility) {
                RecordingStore().totalSize()
            }.value
        }
    }

    private func downloadWhisperModel() {
        isPreparingWhisper = true
        whisperError = nil

        whisperTask = Task {
            do {
                try await WhisperKitRecognizer().prepare()
            } catch is CancellationError {
                // Человек передумал, это не ошибка.
            } catch {
                guard !Task.isCancelled else { return }
                whisperError = error.localizedDescription
            }

            guard !Task.isCancelled else { return }
            isPreparingWhisper = false
            whisperTask = nil
        }
    }

    /// Отменяет ожидание загрузки.
    ///
    /// Саму закачку внутри библиотеки прервать нечем, поэтому она может
    /// докачаться в фоне. Экран об этом больше не врёт: он просто перестаёт
    /// ждать и возвращает кнопку загрузки.
    private func cancelWhisperDownload() {
        whisperTask?.cancel()
        whisperTask = nil
        isPreparingWhisper = false
        whisperError = nil
    }
}

#Preview {
    SettingsView()
        .environment(AppSettings(defaults: .standard))
        .environment(PermissionsManager())
}
