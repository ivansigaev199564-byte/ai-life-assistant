import SwiftUI

/// Экран записи: уровень сигнала, живая расшифровка, кнопки остановки и отмены.
///
/// Показывается поверх инбокса, пока идёт захват. Всё, что нужно пользователю
/// в этот момент, помещается на один экран без прокрутки.
struct RecordingOverlay: View {

    @Environment(CaptureCoordinator.self) private var coordinator

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                statusText

                waveform

                transcript

                Spacer()

                controls
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .contentShape(Rectangle())
    }

    // MARK: Части экрана

    private var statusText: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var title: String {
        switch coordinator.phase {
        case .preparing: return "Готовлю микрофон"
        case .listening: return coordinator.hasDetectedSpeech ? "Слушаю" : "Говорите"
        case .finalizing: return "Обрабатываю"
        case .failed: return "Не получилось"
        case .idle: return ""
        }
    }

    private var subtitle: String {
        switch coordinator.phase {
        case .listening:
            return coordinator.hasDetectedSpeech
                ? "Пауза в полторы секунды остановит запись сама"
                : "Микрофон включён, начните говорить"
        case .finalizing:
            return "Сохраняю запись"
        case .failed(let error):
            return error.errorDescription ?? ""
        default:
            return ""
        }
    }

    /// Индикатор уровня: восемь полос, реагирующих на громкость.
    private var waveform: some View {
        HStack(spacing: 6) {
            ForEach(0..<8, id: \.self) { index in
                Capsule()
                    .fill(.tint)
                    .frame(width: 8, height: barHeight(for: index))
                    .animation(.easeOut(duration: 0.12), value: coordinator.audioLevel)
            }
        }
        .frame(height: 90)
        .accessibilityHidden(true)
    }

    /// Полосы по краям ниже центральных: так индикатор читается как волна,
    /// а не как ровный столбик.
    private func barHeight(for index: Int) -> CGFloat {
        let distanceFromCenter = abs(Double(index) - 3.5) / 3.5
        let shape = 1.0 - distanceFromCenter * 0.55
        let level = Double(min(1, max(0, coordinator.audioLevel)))
        let minimum = 10.0
        let maximum = 80.0
        return minimum + (maximum - minimum) * level * shape
    }

    @ViewBuilder
    private var transcript: some View {
        if coordinator.liveTranscript.isEmpty {
            Text(" ")
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            ScrollView {
                Text(coordinator.liveTranscript)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 160)
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button(role: .cancel) {
                Task { await coordinator.cancel() }
            } label: {
                Label("Отменить", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)

            Button {
                Task { await coordinator.stop(reason: .manual) }
            } label: {
                Label("Готово", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(coordinator.phase == .finalizing)
        }
    }
}

#Preview {
    let preview = AppEnvironment.makeForTesting()
    return RecordingOverlay()
        .environment(preview.coordinator)
}
