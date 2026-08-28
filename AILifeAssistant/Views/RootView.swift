import SwiftData
import SwiftUI

/// Корневой экран: лента записей и кнопка захвата.
///
/// Кнопка живёт внизу, в зоне большого пальца, и остаётся на месте при
/// прокрутке: до неё нужно дотянуться не глядя. Всё остальное на экране
/// уступает ей по контрасту.
struct RootView: View {

    @Environment(CaptureCoordinator.self) private var coordinator
    @Environment(\.capabilities) private var capabilities
    @Environment(AppSettings.self) private var settings
    @Environment(ProcessingQueue.self) private var processingQueue
    @Environment(\.modelContext) private var modelContext

    /// Ссылки из уведомлений и виджета. Отсутствует в предпросмотре.
    @Environment(NotificationRouter.self) private var router: NotificationRouter?

    /// Запись, которую попросили открыть извне.
    @State private var routedCapture: CaptureItem?

    @State private var isShowingSettings = false
    @State private var isShowingReview = false
    @State private var isShowingSearch = false
    @State private var isShowingStats = false
    @State private var isShowingContext = false
    @State private var isShowingTextInput = false
    @State private var draftText = ""
    @State private var isConfirmingDraftDiscard = false

    /// Записи, которые приложение поняло неуверенно.
    ///
    /// Раньше здесь лежала вся таблица захватов, а счётчик проверок ходил
    /// по ней и трогал связи каждой записи. На двух тысячах записей это
    /// давало тысячи отдельных запросов на каждую перерисовку экрана.
    @Query private var uncertainCaptures: [CaptureItem]

    /// Заметки, помеченные на проверку.
    @Query private var uncertainNotes: [Note]

    /// Пробные выборки на одну строку: нужен только ответ «есть или нет».
    @Query private var anyExpense: [Expense]
    @Query private var anyCapture: [CaptureItem]

    init() {
        _uncertainCaptures = Query(
            FetchDescriptor<CaptureItem>(predicate: CaptureItem.needsReviewPredicate)
        )
        _uncertainNotes = Query(
            FetchDescriptor<Note>(predicate: #Predicate { $0.needsReview })
        )

        var expenseProbe = FetchDescriptor<Expense>()
        expenseProbe.fetchLimit = 1
        _anyExpense = Query(expenseProbe)

        var captureProbe = FetchDescriptor<CaptureItem>()
        captureProbe.fetchLimit = 1
        _anyCapture = Query(captureProbe)
    }

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
        !anyExpense.isEmpty
    }

    /// Сколько записей ждут проверки.
    ///
    /// Запись и её заметка могут быть помечены обе, поэтому считаем
    /// по идентификаторам, а не складываем два числа.
    private var reviewCount: Int {
        var identifiers = Set(uncertainCaptures.map(\.id))

        for note in uncertainNotes {
            guard let sourceID = note.source?.id else { continue }
            identifiers.insert(sourceID)
        }

        return identifiers.count
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
            .sheet(isPresented: $isShowingContext) { ContextView() }
            .sheet(isPresented: $isShowingTextInput) { textInputSheet }
            .navigationDestination(item: $routedCapture) { capture in
                CaptureDetailView(capture: capture, processingQueue: processingQueue)
            }
            .fullScreenCover(isPresented: showOnboarding) {
                OnboardingView {
                    settings.hasCompletedOnboarding = true
                }
            }
            .animation(DS.Motion.phase, value: coordinator.phase)
            // Экран записи и баннеры живут в отдельном окне поверх всего:
            // здесь они прятались за любым открытым листом.
            .task { openPendingLink() }
            .onChange(of: router?.pendingLink) { _, _ in openPendingLink() }
        }
    }

    // MARK: Переходы извне

    /// Открывает запись, о которой говорит уведомление или виджет.
    private func openPendingLink() {
        guard let link = router?.consume() else { return }

        switch link {
        case .today:
            routedCapture = nil
        case .capture(let id):
            routedCapture = capture(with: id)
        case .reminder(let id):
            routedCapture = reminder(with: id)?.source
        case .task(let id):
            routedCapture = task(with: id)?.source
        }
    }

    private func capture(with id: UUID) -> CaptureItem? {
        var descriptor = FetchDescriptor<CaptureItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func reminder(with id: UUID) -> Reminder? {
        var descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func task(with id: UUID) -> TaskItem? {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: Шапка

    private var header: some View {
        ScreenHeader(title: "Инбокс", subtitle: subtitle) {
            AnyView(
                HStack(spacing: DS.Spacing.xs) {
                    if !anyCapture.isEmpty {
                        Button {
                            isShowingSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(CircleButtonStyle())
                        .accessibilityLabel("Поиск")
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

                    // Всё, что открывают изредка, собрано в одно меню:
                    // ряд из пяти кнопок в верхнем углу и выглядит тесно,
                    // и требует целиться.
                    Menu {
                        if hasExpenses {
                            Button {
                                isShowingStats = true
                            } label: {
                                Label("Расходы", systemImage: "chart.pie")
                            }
                        }

                        Button {
                            isShowingContext = true
                        } label: {
                            Label("Люди и проекты", systemImage: "person.2")
                        }

                        Button {
                            draftText = ""
                            isShowingTextInput = true
                        } label: {
                            Label("Ввести текстом", systemImage: "square.and.pencil")
                        }

                        Divider()

                        Button {
                            isShowingSettings = true
                        } label: {
                            Label("Настройки", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(CircleButtonStyle())
                    .accessibilityLabel("Меню")
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
                    Button("Отмена") {
                        if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            isShowingTextInput = false
                        } else {
                            isConfirmingDraftDiscard = true
                        }
                    }
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
        // Свайп вниз стирал набранный текст молча. Пока черновик не пуст,
        // лист закрывается только через кнопку, и та переспрашивает.
        .interactiveDismissDisabled(!draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .confirmationDialog(
            "Удалить черновик?",
            isPresented: $isConfirmingDraftDiscard,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                draftText = ""
                isShowingTextInput = false
            }
            Button("Продолжить писать", role: .cancel) {}
        }
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
