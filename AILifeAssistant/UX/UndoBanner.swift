import SwiftUI

/// Баннер отмены последнего действия.
///
/// Живёт над кнопкой записи и уходит сам через пять секунд. Полоса
/// обратного отсчёта показывает, сколько осталось: без неё исчезновение
/// баннера выглядит случайным, а с ней понятно, что время кончается,
/// и решение нужно принять сейчас.
struct UndoBanner: View {

    let action: UndoService.Action
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @State private var progress: Double = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(DS.Palette.success)

                Text(action.message)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(2)

                Spacer(minLength: DS.Spacing.xs)

                Button("Отменить", action: onUndo)
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.accent)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)

            // Полоса времени: сколько ещё можно передумать.
            GeometryReader { geometry in
                Rectangle()
                    .fill(DS.Palette.accent.opacity(0.5))
                    .frame(width: geometry.size.width * progress)
            }
            .frame(height: 2)
        }
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(DS.Palette.surface)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(DS.Palette.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .onAppear {
            progress = 1
            withAnimation(.linear(duration: UndoService.window)) {
                progress = 0
            }
        }
        // Смахивание вниз убирает баннер, не отменяя действие: жест
        // привычный и не требует целиться в маленькую кнопку.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height > 20 { onDismiss() }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Отменить", onUndo)
    }
}

#Preview {
    let action = UndoService.Action(
        kind: .captureCreated(UUID()),
        message: "Создано: расход 300 ₽, напоминание на 9:00",
        createdAt: .now
    )

    return VStack {
        Spacer()
        UndoBanner(action: action, onUndo: {}, onDismiss: {})
            .padding()
    }
    .background(DS.Palette.background)
}
