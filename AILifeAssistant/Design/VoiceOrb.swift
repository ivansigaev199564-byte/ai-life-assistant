import SwiftUI

/// Визуализатор голоса: то единственное, на что пользователь смотрит,
/// пока говорит.
///
/// Решение сознательное: вместо привычной полосы-эквалайзера здесь одна
/// живая форма. Полоски требуют разглядывания, чтобы понять, слышит ли
/// микрофон. Пульсирующий круг считывается боковым зрением за долю секунды,
/// а именно так на него и смотрят: мельком, продолжая говорить.
struct VoiceOrb: View {

    /// Уровень сигнала 0...1.
    let level: Float
    /// Идёт ли запись. В паузе орб дышит медленно, без реакции на звук.
    let isActive: Bool

    @State private var breathing = false

    private var normalizedLevel: CGFloat {
        CGFloat(min(1, max(0, level)))
    }

    var body: some View {
        ZStack {
            // Внешние кольца отзываются на голос с разной силой,
            // отчего форма выглядит живой, а не механически ровной.
            ForEach(0..<3, id: \.self) { index in
                let delayFactor = 1 - CGFloat(index) * 0.22
                Circle()
                    .stroke(DS.Palette.accent.opacity(0.16 - Double(index) * 0.04), lineWidth: 1.5)
                    .scaleEffect(1 + normalizedLevel * 0.45 * delayFactor + CGFloat(index) * 0.16)
                    .animation(DS.Motion.level, value: level)
            }

            // Свечение под основным кругом даёт ощущение объёма
            // без единой картинки в бандле.
            Circle()
                .fill(DS.recordingGradient)
                .frame(width: 132, height: 132)
                .blur(radius: 28)
                .opacity(0.5 + Double(normalizedLevel) * 0.35)
                .scaleEffect(breathing ? 1.06 : 0.94)

            Circle()
                .fill(DS.recordingGradient)
                .frame(width: 108, height: 108)
                .scaleEffect(1 + normalizedLevel * 0.18)
                .animation(DS.Motion.level, value: level)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                        .scaleEffect(1 + normalizedLevel * 0.18)
                }

            Image(systemName: isActive ? "waveform" : "mic.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(1 + normalizedLevel * 0.08)
                .animation(DS.Motion.level, value: level)
        }
        .frame(width: 220, height: 220)
        .onAppear {
            withAnimation(DS.Motion.breathe) { breathing = true }
        }
        .accessibilityHidden(true)
    }
}

/// Тонкая полоса уровня для компактных мест, где орб не помещается.
struct LevelBar: View {

    let level: Float
    var barCount = 5

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(DS.Palette.accent)
                    .frame(width: 3, height: height(for: index))
                    .animation(DS.Motion.level, value: level)
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    /// Центральные полосы выше крайних: так столбик читается как звук.
    private func height(for index: Int) -> CGFloat {
        let distance = abs(Double(index) - Double(barCount - 1) / 2)
        let shape = 1 - distance / Double(barCount)
        let value = Double(min(1, max(0, level)))
        return 4 + 14 * value * shape
    }
}

#Preview("Орб") {
    VStack(spacing: 40) {
        VoiceOrb(level: 0.15, isActive: true)
        LevelBar(level: 0.6)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DS.Palette.background)
}
