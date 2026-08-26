import SwiftUI

/// Токены визуального языка приложения.
///
/// Продукт голосовой: пользователь смотрит на экран считаные секунды в день,
/// обычно на ходу и часто в темноте. Отсюда три решения, определяющие всю
/// систему: тёмная база как основной режим, крупная типографика с высоким
/// контрастом и цвет, который несёт смысл, а не украшает.
enum DS {

    // MARK: Цвет

    /// Цвет, зависящий от темы. SwiftUI сам подхватит смену оформления.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark)
                : UIColor(hex: light)
        })
    }

    enum Palette {
        /// Фон приложения. В тёмной теме почти чёрный с синим подтоном:
        /// чистый чёрный на OLED даёт слишком резкий край у карточек.
        static let background = DS.adaptive(light: 0xF4F5F9, dark: 0x0A0B10)

        /// Поверхность карточки.
        static let surface = DS.adaptive(light: 0xFFFFFF, dark: 0x15171F)

        /// Приподнятая поверхность: вложенные блоки, чипы.
        static let surfaceElevated = DS.adaptive(light: 0xF0F1F6, dark: 0x1E212B)

        /// Разделители и границы.
        static let border = DS.adaptive(light: 0xE2E4EC, dark: 0x272B37)

        static let textPrimary = DS.adaptive(light: 0x0E1116, dark: 0xF2F4F8)
        static let textSecondary = DS.adaptive(light: 0x5C6270, dark: 0x9AA1B2)
        static let textTertiary = DS.adaptive(light: 0x8B909D, dark: 0x646B7C)

        /// Основной акцент. Электрический синий читается и на светлом,
        /// и на тёмном, и не сливается с семантическими цветами сущностей.
        static let accent = DS.adaptive(light: 0x2F5BFF, dark: 0x5B7CFF)

        /// Второй акцент для градиента записи.
        static let accentSecondary = DS.adaptive(light: 0x7B3FFF, dark: 0x9B6BFF)

        static let danger = DS.adaptive(light: 0xE03B3B, dark: 0xFF6B6B)
        static let warning = DS.adaptive(light: 0xD98200, dark: 0xFFB13D)
        static let success = DS.adaptive(light: 0x14915B, dark: 0x35D08A)
    }

    /// Цвет по типу сущности. Один взгляд на список должен давать понимание,
    /// что там: трата, напоминание или мысль. Это работает быстрее текста.
    enum EntityColor {
        static let expense = DS.adaptive(light: 0x14915B, dark: 0x35D08A)
        static let reminder = DS.adaptive(light: 0xD98200, dark: 0xFFB13D)
        static let task = DS.adaptive(light: 0x2F5BFF, dark: 0x5B7CFF)
        static let note = DS.adaptive(light: 0x7C8496, dark: 0x8992A6)

        static func forKind(_ kind: ParsedItemKind) -> Color {
            switch kind {
            case .expense: return expense
            case .reminder: return reminder
            case .task: return task
            case .note: return note
            }
        }
    }

    /// Градиент активной записи: единственное место в приложении,
    /// где цвет позволяет себе быть ярким.
    static var recordingGradient: LinearGradient {
        LinearGradient(
            colors: [Palette.accent, Palette.accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Типографика

    /// Шкала на системном шрифте: он лучше всех справляется с русским
    /// и английским сразу и корректно тянется под размер шрифта системы.
    enum Font {
        /// Крупный заголовок экрана.
        static let display = SwiftUI.Font.system(size: 32, weight: .bold, design: .rounded)
        /// Заголовок раздела.
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold, design: .rounded)
        /// Живая расшифровка речи: должна читаться с вытянутой руки.
        static let transcript = SwiftUI.Font.system(size: 24, weight: .medium, design: .rounded)
        /// Основной текст записи.
        static let body = SwiftUI.Font.system(size: 16, weight: .regular)
        /// Заголовок карточки сущности.
        static let entityTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// Подпись, метаданные.
        static let caption = SwiftUI.Font.system(size: 13, weight: .medium)
        /// Мелкая служебная подпись.
        static let micro = SwiftUI.Font.system(size: 11, weight: .semibold)
        /// Денежная сумма: моноширинные цифры, чтобы колонка не прыгала.
        static let amount = SwiftUI.Font.system(size: 15, weight: .semibold).monospacedDigit()
    }

    // MARK: Метрика

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
        static let pill: CGFloat = 999
    }

    // MARK: Движение

    /// Анимации короткие и пружинные: интерфейс должен ощущаться живым,
    /// но никогда не заставлять ждать себя.
    enum Motion {
        /// Появление и исчезновение элементов списка.
        static let enter = Animation.spring(response: 0.38, dampingFraction: 0.82)
        /// Реакция на нажатие.
        static let tap = Animation.spring(response: 0.24, dampingFraction: 0.7)
        /// Смена состояния экрана записи.
        static let phase = Animation.spring(response: 0.42, dampingFraction: 0.85)
        /// Уровень звука: почти без инерции, иначе индикатор врёт.
        static let level = Animation.easeOut(duration: 0.1)
        /// Медленное дыхание фона во время записи.
        static let breathe = Animation.easeInOut(duration: 2.4).repeatForever(autoreverses: true)
    }
}

// MARK: Вспомогательное

extension UIColor {
    /// Инициализация из шестнадцатеричного значения вида 0x1E212B.
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
