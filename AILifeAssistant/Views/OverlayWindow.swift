import SwiftUI
import UIKit

/// Окно поверх всего остального.
///
/// Оверлей внутри обычной иерархии перекрывается любым открытым листом:
/// человек нажимает Кнопку действия, стоя в настройках или в карточке
/// записи, микрофон включается, а на экране не меняется ничего. Отдельное
/// окно снимает это раз и навсегда, оно живёт выше листов, меню и модальных
/// экранов.
///
/// Касания мимо содержимого проваливаются вниз, поэтому окно годится и для
/// баннеров, которые не должны блокировать приложение.
private final class PassthroughWindow: UIWindow {

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // Попали в саму подложку, а не в баннер или оверлей: пропускаем
        // касание в приложение под окном.
        return rootViewController?.view === hit ? nil : hit
    }
}

@MainActor
final class OverlayWindowController {

    private var window: UIWindow?

    func show(_ content: some View) {
        guard window == nil, let scene = Self.activeScene else { return }

        let controller = UIHostingController(rootView: AnyView(content))
        controller.view.backgroundColor = .clear
        // Иначе контроллер закрашивает весь экран непрозрачным фоном
        // и приложение под окном исчезает.
        controller.view.isOpaque = false

        let window = PassthroughWindow(windowScene: scene)
        window.rootViewController = controller
        window.backgroundColor = .clear
        window.isOpaque = false
        // Выше системных предупреждений: запись важнее всего, что может
        // оказаться на экране в этот момент.
        window.windowLevel = .alert + 1
        window.isHidden = false

        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

private struct OverlayWindowModifier<Overlay: View>: ViewModifier {

    let isPresented: Bool
    @ViewBuilder let overlay: () -> Overlay

    @State private var controller = OverlayWindowController()

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onChange(of: isPresented) { _, _ in sync() }
            .onDisappear { controller.hide() }
    }

    private func sync() {
        if isPresented {
            controller.show(overlay())
        } else {
            controller.hide()
        }
    }
}

extension View {

    /// Показывает содержимое в отдельном окне поверх всего приложения.
    ///
    /// Окружение в такое окно не наследуется, поэтому нужные объекты
    /// передаются в замыкании явно.
    func overlayWindow<Content: View>(
        isPresented: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(OverlayWindowModifier(isPresented: isPresented, overlay: content))
    }
}
