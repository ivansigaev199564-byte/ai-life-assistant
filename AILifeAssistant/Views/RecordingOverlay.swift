import SwiftUI

/// Экран записи: единственный момент, когда пользователь смотрит
/// на приложение осознанно.
///
/// Всё подчинено одному вопросу, который у него в голове: «меня слышно?».
/// Ответ даёт орб, который реагирует на голос, и текст, который появляется
/// по мере речи. Управление отодвинуто вниз и намеренно не притягивает
/// внимание: чаще всего запись остановится сама по тишине.
struct RecordingOverlay: View {

    @Environment(CaptureCoordinator.self) private var coordinator

    @State private var appeared = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer(minLength: DS.Spacing.xl)

                status
                    .padding(.bottom, DS.Spacing.xl)

                VoiceOrb(level: coordinator.audioLevel, isActive: coordinator.phase == .listening)
                    .scaleEffect(appeared ? 1 : 0.86)
                    .opacity(appeared ? 1 : 0)

                transcript
                    .padding(.top, DS.Spacing.lg)
                    .padding(.horizontal, DS.Spacing.lg)

                Spacer(minLength: DS.Spacing.lg)

                controls
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.bottom, DS.Spacing.xl)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)
            }
        }
        .onAppear {
            withAnimation(DS.Motion.phase) { appeared = true }
        }
    }

    // MARK: Фон

    /// Тёмная подложка с еле заметным свечением сверху: оно поднимает
    /// орб над фоном и задаёт вертикаль экрана.
    private var background: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            RadialGradient(
                colors: [DS.Palette.accent.opacity(0.18), .clear],
                center: .init(x: 0.5, y: 0.32),
                startRadius: 10,
                endRadius: 340
            )
            .ignoresSafeArea()
            .opacity(coordinator.phase == .listening ? 1 : 0.4)
            .animation(DS.Motion.phase, value: coordinator.phase)
        }
    }

    // MARK: Состояние

    private var status: some View {
        VStack(spacing: DS.Spacing.xxs) {
            Text(title)
                .font(DS.Font.title)
                .foregroundStyle(DS.Palette.textPrimary)
                .contentTransition(.opacity)

            Text(subtitle)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .animation(DS.Motion.phase, value: coordinator.phase)
        .animation(DS.Motion.phase, value: coordinator.hasDetectedSpeech)
        // Смена состояния проговаривается вслух: незрячий пользователь
        // не видит орба и должен как-то узнать, что микрофон услышал речь.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var title: String {
        switch coordinator.phase {
        case .preparing: return "Включаю микрофон"
        case .listening: return coordinator.hasDetectedSpeech ? "Слушаю" : "Говорите"
        case .finalizing: return "Записываю"
        case .failed: return "Не получилось"
        case .idle: return ""
        }
    }

    private var subtitle: String {
        switch coordinator.phase {
        case .listening:
            return coordinator.hasDetectedSpeech
                ? "Замолчите на секунду, и запись закроется сама"
                : "Микрофон включён"
        case .finalizing:
            return "Сохраняю и разбираю"
        case .failed(let error):
            return error.errorDescription ?? ""
        default:
            return ""
        }
    }

    // MARK: Расшифровка

    /// Живой текст растёт снизу вверх и не прыгает при обновлении:
    /// фиксированная область высоты держит орб на месте.
    @ViewBuilder
    private var transcript: some View {
        if coordinator.liveTranscript.isEmpty {
            Color.clear.frame(height: 96)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                Text(coordinator.liveTranscript)
                    .font(DS.Font.transcript)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .accessibilityLabel("Распознано: " + coordinator.liveTranscript)
            }
            .frame(height: 96)
            .animation(DS.Motion.enter, value: coordinator.liveTranscript)
        }
    }

    // MARK: Управление

    private var controls: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button {
                Task { await coordinator.cancel() }
            } label: {
                Label("Отменить", systemImage: "xmark")
            }
            .buttonStyle(PrimaryButtonStyle(isProminent: false))

            Button {
                Task { await coordinator.stop(reason: .manual) }
            } label: {
                Label("Готово", systemImage: "checkmark")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(coordinator.phase == .finalizing)
        }
    }
}

#Preview {
    let preview = AppEnvironment.makeForTesting()
    return RecordingOverlay()
        .environment(preview.coordinator)
        .background(DS.Palette.background)
}
