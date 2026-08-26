import SwiftUI

/// Строка захвата в инбоксе: текст, статус обработки и метаданные.
struct CaptureRowView: View {

    let capture: CaptureItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                statusIcon

                Text(capture.previewText)
                    .font(.body)
                    .lineLimit(4)
                    .foregroundStyle(capture.status == .failed ? .secondary : .primary)
            }

            HStack(spacing: 8) {
                Text(capture.createdAt.formatted(date: .omitted, time: .shortened))

                if capture.audioDuration > 0 {
                    Label(
                        Self.durationText(capture.audioDuration),
                        systemImage: "waveform"
                    )
                }

                if capture.engine != .none {
                    Text(capture.engine.displayName)
                }

                if capture.recognitionConfidence > 0, capture.recognitionConfidence < 0.7 {
                    // Низкая уверенность распознавания: на Этапе 5 такие записи
                    // получат тег на проверку, сейчас просто помечаем визуально.
                    Label("проверить", systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 0)

                if capture.derivedItemsCount > 0 {
                    Text("\(capture.derivedItemsCount)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let failureReason = capture.failureReason {
                Text(failureReason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch capture.status {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        case .processing:
            ProgressView()
                .controlSize(.small)
        case .synced:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) с" }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

#Preview {
    let capture = CaptureItem(
        text: "Напомни завтра в девять позвонить Мише и купил кофе за триста рублей",
        status: .pending,
        source: .actionButton,
        engine: .appleSpeech,
        recognitionConfidence: 0.92,
        audioDuration: 4.2
    )
    return List {
        CaptureRowView(capture: capture)
    }
}
