import SwiftUI
import UIKit

/// Системный лист «Поделиться».
///
/// SwiftUI умеет ShareLink, но он требует, чтобы файл существовал
/// на момент построения представления. Выгрузка готовится по нажатию,
/// поэтому проще обернуть системный контроллер.
struct ShareSheet: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
