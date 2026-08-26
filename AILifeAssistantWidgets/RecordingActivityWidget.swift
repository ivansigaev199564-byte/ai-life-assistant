import ActivityKit
import SwiftUI
import WidgetKit

/// Отображение записи в Динамическом острове и на экране блокировки.
///
/// Компоновка подчинена тому, как на остров смотрят: мельком, боковым
/// зрением, не прерывая речь. Поэтому в свёрнутом виде только пульсирующая
/// точка и время, а текст появляется лишь в развёрнутом, когда человек
/// сам решил посмотреть.
struct RecordingActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptureActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.isSpeaking ? "Слушаю" : "Говорите")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.tint)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(durationText(context.state.elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.transcript.isEmpty {
                        levelBars(level: context.state.audioLevel)
                    } else {
                        Text(context.state.transcript)
                            .font(.callout)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                // Компактная область крошечная: полосы уровня читаются
                // в ней лучше, чем цифры или текст.
                levelBars(level: context.state.audioLevel, barCount: 3)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.tint)
            }
            .keylineTint(.accentColor)
        }
    }

    // MARK: Экран блокировки

    private func lockScreenView(
        context: ActivityViewContext<CaptureActivityAttributes>
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.15))
                    .frame(width: 40, height: 40)

                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.isSpeaking ? "Слушаю" : "Говорите")
                    .font(.subheadline.weight(.semibold))

                if context.state.transcript.isEmpty {
                    Text("Микрофон включён")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(context.state.transcript)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Text(durationText(context.state.elapsed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: Индикатор уровня

    private func levelBars(level: Double, barCount: Int = 4) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                let distance = abs(Double(index) - Double(barCount - 1) / 2)
                let shape = 1 - distance / Double(barCount)
                Capsule()
                    .fill(.tint)
                    .frame(width: 2.5, height: 4 + 12 * level * shape)
            }
        }
        .frame(height: 16)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
