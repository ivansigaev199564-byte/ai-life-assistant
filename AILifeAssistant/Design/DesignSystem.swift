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
        /// Третичный текст. Значения подобраны так, чтобы проходить
        /// порог контраста 4.5:1 на своём фоне: прежние выглядели
        /// приятнее, но читались только на хорошем экране при хорошем свете.
        static let textTertiary = DS.adaptive(light: 0x707584, dark: 0x7A8193)

        /// Основной акцент. Электрический синий читается и на светлом,
        /// и на тёмном, и не сливается с семантическими цветами сущностей.
        static let accent = DS.adaptive(light: 0x2F5BFF, dark: 0x5B7CFF)

        /// Второй акцент для градиента записи.
        static let accentSecondary = DS.adaptive(light: 0x7B3FFF, dark: 0x9B6BFF)

        static let danger = DS.adaptive(light: 0xDE3232, dark: 0xFF6B6B)
        static let warning = DS.adaptive(light: 0xAB6600, dark: 0xFFB13D)
        static let success = DS.adaptive(light: 0x128352, dark: 0x35D08A)

        /// Заливка кнопок. Отличается от accent намеренно: на светлом
        /// акценте тёмной темы белый текст даёт всего 3.6:1, а на кнопке
        /// текст обязан читаться при любом освещении.
        static let accentFill = DS.adaptive(light: 0x2F5BFF, dark: 0x4167FF)
        static let accentFillSecondary = DS.adaptive(light: 0x7B3FFF, dark: 0x864CFF)
    }

    /// Цвет по типу сущности. Один взгляд на список должен давать понимание,
    /// что там: трата, напоминание или мысль. Это работает быстрее текста.
    ///
    /// Светлые варианты заметно темнее очевидных: цвет здесь идёт текстом
    /// на подложке того же оттенка, и на такой паре контраст падает вдвое
    /// против цвета на белом.
    enum EntityColor {
        static let expense = DS.adaptive(light: 0x107A4C, dark: 0x35D08A)
        static let reminder = DS.adaptive(light: 0x965A00, dark: 0xFFB13D)
        static let task = DS.adaptive(light: 0x2956FE, dark: 0x6584FF)
        static let note = DS.adaptive(light: 0x636A7B, dark: 0x8992A6)

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
            colors: [Palette.accentFill, Palette.accentFillSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Типографика

    /// Шкала на системном шрифте.
    ///
    /// Каждый размер привязан к текстовому стилю, а не задан числом:
    /// иначе приложение игнорирует системную настройку размера шрифта.
    /// Для продукта, которым пользуются на ходу и часто в возрасте,
    /// это не мелочь: человек увеличил шрифт во всей системе, а здесь
    /// остался прежний мелкий.
    enum Font {
        /// Крупный заголовок экрана.
        static let display = SwiftUI.Font.system(.largeTitle, design: .rounded, weight: .bold)
        /// Заголовок раздела.
        static let title = SwiftUI.Font.system(.title2, design: .rounded, weight: .semibold)
        /// Живая расшифровка речи: должна читаться с вытянутой руки.
        static let transcript = SwiftUI.Font.system(.title2, design: .rounded, weight: .medium)
        /// Основной текст записи.
        static let body = SwiftUI.Font.system(.callout)
        /// Заголовок карточки сущности.
        static let entityTitle = SwiftUI.Font.system(.subheadline, weight: .semibold)
        /// Подпись, метаданные.
        static let caption = SwiftUI.Font.system(.footnote, weight: .medium)
        /// Мелкая служебная подпись.
        static let micro = SwiftUI.Font.system(.caption2, weight: .semibold)
        /// Денежная сумма: моноширинные цифры, чтобы колонка не прыгала.
        static let amount = SwiftUI.Font.system(.subheadline, weight: .semibold).monospacedDigit()
    }

    /// Предел увеличения шрифта для плотных мест.
    ///
    /// Полностью запрещать крупный шрифт нельзя, это и есть та самая
    /// недоступность. Но плашки сущностей и полосы метаданных при
    /// максимальном размере превращаются в кашу, поэтому им ставится
    /// потолок, а основному тексту нет.
    static let denseTypeLimit: DynamicTypeSize = .accessibility1

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
