import SwiftUI
import WidgetKit

/// Набор расширений приложения.
@main
struct AILifeAssistantWidgetBundle: WidgetBundle {

    var body: some Widget {
        TodayWidget()
        QuickCaptureWidget()
        RecordingActivityWidget()

        // Элемент Пункта управления появился в iOS 18: на более ранних
        // системах набор просто не включает его.
        if #available(iOS 18.0, *) {
            CaptureControl()
        }
    }
}
