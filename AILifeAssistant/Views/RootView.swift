import SwiftData
import SwiftUI

/// Корневой экран: лента записей и кнопка захвата.
///
/// Кнопка живёт внизу, в зоне большого пальца, и остаётся на месте при
/// прокрутке: до неё нужно дотянуться не глядя. Всё остальное на экране
/// уступает ей по контрасту.
struct RootView: View {

    @Environment(CaptureCoordinator.self) private var coordinator
    @Environment(PermissionsManager.self) private var permissions
    @Environment(\.capabilities) private var capabilities
    @Environment(AppSettings.self) private var settings
    @Environment(UndoService.self) private var undoService
    @Environment(ProcessingQueue.self) private var processingQueue

    @State private var isShowingSettings = false
    @State private var isShowingReview = false
    @State private var isShowingSearch = false
    @State private var isShowingStats = false
    @State private var isShowingTextInput = false
    @State private var draftText = ""

    /// Записи, которые приложение поняло неуверенно.
    @Query private var allCaptures: [CaptureItem]

    /// Первый запуск: голосовой интерфейс не объясняет себя сам,
    /// и без примеров фраз человек просто не знает, что сказать.
    private var showOnboarding: Binding<Bool> {
        Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { shown in if !shown { settings.hasCompletedOnboarding = true } }
        )
    }

    /// Есть ли траты: без них экран расходов пуст и в шапке не нужен.
    private var hasExpenses: Bool {
        allCaptures.contains { !$0.expenses.isEmpty }
    }

    private var reviewCount: Int {
        allCaptures.filter { $0.needsReview || $0.notes.contains(where: \.needsReview) }.count
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                DS.Palette.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    TimelineView()
                }

                captureBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $isShowingSettings) { SettingsView() }
            .sheet(isPresented: $isShowingReview) {
                ReviewInboxView(processingQueue: processingQueue)
            }
            .sheet(isPresented: $isShowingSearch) { SearchView() }
            .sheet(isPresented: $isShowingStats) { StatsView() }
            .sheet(isPresented: $isShowingTextInput) { textInputSheet }
            .overlay {
                if coordinator.phase.isActive {
                    RecordingOverlay()
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .fullScreenCover(isPresented: showOnboarding) {
                OnboardingView {
                    settings.hasCompletedOnboarding = true
                }
            }
            .animation(DS.Motion.phase, value: coordinator.phase)
            .animation(DS.Motion.enter, value: undoService.pending?.id)
        }
    }

    // MARK: Шапка

    private var header: some View {
        ScreenHeader(title: "Инбокс", subtitle: subtitle) {
            AnyView(
                HStack(spacing: DS.Spacing.xs) {
                    if !allCaptures.isEmpty {
                        Button {
                            isShowingSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(CircleButtonStyle())
                        .accessibilityLabel("Поиск")
                    }

                    if hasExpenses {
                        Button {
                            isShowingStats = true
                        } label: {
                            Image(systemName: "chart.pie")
                        }
                        .buttonStyle(CircleButtonStyle())
                        .accessibilityLabel("Расходы")
                    }

                    if reviewCount > 0 {
                        Button {
                            isShowingReview = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .overlay(alignment: .topTrailing) {
                                    Circle()
                                        .fill(DS.Palette.warning)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 3, y: -3)
                                }
                        }
                        .buttonStyle(CircleButtonStyle())
                        .accessibilityLabel("На проверку, записей: \(reviewCount)")
                    }

                    Button {
                        draftText = ""
                        isShowingTextInput = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(CircleButtonStyle())
                    .accessibilityLabel("Ввести текстом")

                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(CircleButtonStyle())
                    .accessibilityLabel("Настройки")
                }
            )
        }
    }

    /// Подсказка о том, как быстрее всего записывать, без нотаций:
    /// одна строка, которая отвечает на вопрос «а можно быстрее».
    private var subtitle: String {
        switch capabilities.primaryTrigger {
        case .actionButton: return "Кнопка действия запишет быстрее всего"
        case .controlCenter: return "Добавьте запись в Пункт управления"
        case .widgetOrShortcut: return "Добавьте виджет на экран блокировки"
        }
    }

    // MARK: Нижняя панель

    private var captureBar: some View {
        VStack(spacing: DS.Spacing.xs) {
            if case .failed(let error) = coordinator.phase {
                errorBanner(error)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Баннер отмены стоит над кнопкой записи: именно туда смотрит
            // человек сразу после того, как отпустил её.
            if let pending = undoService.pending {
                UndoBanner(
                    action: pending,
                    onUndo: { undoService.undo() },
                    onDismiss: { undoService.dismiss() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button {
                Task { await coordinator.start(source: .inApp) }
            } label: {
                Label("Говорить", systemImage: "mic.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(coordinator.phase.isActive)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.sm)
        .background {
            // Мягкая растушёвка снизу: карточки уходят под кнопку,
            // а не обрываются под ней резкой линией.
            LinearGradient(
                colors: [DS.Palette.background.opacity(0), DS.Palette.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 140)
            .allowsHitTesting(false)
            .offset(y: 20)
        }
    }

    private func errorBanner(_ error: AppError) -> some View {
        SurfaceCard(padding: DS.Spacing.sm) {
            HStack(alignment: .top, spacing: DS.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Palette.warning)

                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    Text(error.errorDescription ?? "Ошибка")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textPrimary)

                    if error.suggestsSystemSettings {
                        Button("Открыть настройки") {
                            permissions.openSystemSettings()
                        }
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.accent)
                    }
                }
            }
        }
    }

    // MARK: Ввод текстом

    private var textInputSheet: some View {
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
                    .frame(minHeight: 160)

                Text("Текст попадёт в инбокс и будет разобран так же, как голосовая запись.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)

                Spacer()
            }
            .padding(DS.Spacing.md)
            .background(DS.Palette.background)
            .navigationTitle("Новая запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { isShowingTextInput = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        coordinator.saveTextCapture(draftText)
                        draftText = ""
                        isShowingTextInput = false
                    }
                    .fontWeight(.semibold)
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    let preview = AppEnvironment.makeForTesting()
    return RootView()
        .environment(preview.coordinator)
        .environment(preview.settings)
        .environment(preview.permissions)
        .environment(preview.processingQueue)
        .environment(UndoService(modelContext: preview.container.mainContext))
        .environment(
            SearchService(
                modelContext: preview.container.mainContext,
                networkMonitor: NetworkMonitor()
            )
        )
        .modelContainer(preview.container)
}
