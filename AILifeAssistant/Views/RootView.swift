import SwiftData
import SwiftUI

/// Корневой экран: инбокс с записями и кнопка захвата.
struct RootView: View {

    @Environment(CaptureCoordinator.self) private var coordinator
    @Environment(PermissionsManager.self) private var permissions
    @Environment(\.capabilities) private var capabilities

    @State private var isShowingSettings = false
    @State private var isShowingTextInput = false
    @State private var draftText = ""

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                TimelineView()

                captureBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            .navigationTitle("Инбокс")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Настройки")
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingTextInput = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Ввести текстом")
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $isShowingTextInput) {
                textInputSheet
            }
            .overlay {
                if coordinator.phase.isActive {
                    RecordingOverlay()
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.snappy(duration: 0.22), value: coordinator.phase)
        }
    }

    // MARK: Нижняя панель захвата

    private var captureBar: some View {
        VStack(spacing: 10) {
            if case .failed(let error) = coordinator.phase {
                errorBanner(error)
            }

            HStack(spacing: 14) {
                Button {
                    Task { await coordinator.start(source: .inApp) }
                } label: {
                    Label("Говорить", systemImage: "mic.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(coordinator.phase.isActive)
            }

            if capabilities.device.hasActionButton {
                Text("Совет: назначьте кнопку действия на «Быструю запись»")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Совет: добавьте «Быструю запись» в Пункт управления")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorBanner(_ error: AppError) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(error.errorDescription ?? "Ошибка")
                    .font(.subheadline.weight(.medium))

                if error.suggestsSystemSettings {
                    Button("Открыть настройки") {
                        permissions.openSystemSettings()
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Ручной ввод

    private var textInputSheet: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                TextEditor(text: $draftText)
                    .font(.body)
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    .frame(minHeight: 160)

                Text("Текст попадёт в инбокс и будет разобран так же, как голосовая запись.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .navigationTitle("Новая запись")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        draftText = ""
                        isShowingTextInput = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        coordinator.saveTextCapture(draftText)
                        draftText = ""
                        isShowingTextInput = false
                    }
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
        .modelContainer(preview.container)
}
