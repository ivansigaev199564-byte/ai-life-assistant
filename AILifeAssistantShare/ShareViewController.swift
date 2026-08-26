import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Расширение «Поделиться»: приём текста, ссылок и картинок из других
/// приложений.
///
/// Пишет прямо в общую базу приложения, а не передаёт данные через файлы
/// или уведомления. Расширение живёт в отдельном процессе, и любая попытка
/// «разбудить» приложение ради сохранения означала бы потерю данных,
/// когда система решит процесс не запускать.
final class ShareViewController: UIViewController {

    private var container: ModelContainer?

    override func viewDidLoad() {
        super.viewDidLoad()

        do {
            container = try Persistence.makeContainer()
        } catch {
            finish(with: "Не удалось открыть хранилище")
            return
        }

        Task { await handleSharedContent() }
    }

    // MARK: Приём содержимого

    private func handleSharedContent() async {
        guard
            let item = extensionContext?.inputItems.first as? NSExtensionItem,
            let attachments = item.attachments
        else {
            finish(with: "Нечего сохранять")
            return
        }

        var collected: [String] = []

        for attachment in attachments {
            if let text = await loadText(from: attachment) {
                collected.append(text)
            } else if let url = await loadURL(from: attachment) {
                collected.append(url.absoluteString)
            } else if await attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // Картинку не разбираем: распознавание текста на изображении
                // это отдельная работа, и делать её в расширении с жёстким
                // лимитом памяти неразумно. Сохраняем пометку, чтобы
                // приложение обработало снимок позже.
                collected.append("Изображение из другого приложения")
            }
        }

        // Текст самого элемента: некоторые приложения кладут заголовок
        // в attributedContentText, а не во вложения.
        if let title = item.attributedContentText?.string, !title.isEmpty {
            collected.append(title)
        }

        let text = collected
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            finish(with: "Нечего сохранять")
            return
        }

        save(text: text)
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                continuation.resume(returning: item as? String)
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                continuation.resume(returning: item as? URL)
            }
        }
    }

    // MARK: Сохранение

    private func save(text: String) {
        guard let container else {
            finish(with: "Хранилище недоступно")
            return
        }

        let context = ModelContext(container)
        let capture = CaptureItem(
            text: text,
            status: .pending,
            source: .shareExtension,
            engine: .none,
            recognitionConfidence: 1
        )
        context.insert(capture)

        do {
            try context.save()
            finish(with: "Сохранено в инбокс")
        } catch {
            finish(with: "Не удалось сохранить")
        }
    }

    // MARK: Завершение

    /// Показывает короткое подтверждение и закрывается.
    ///
    /// Расширение сознательно без интерфейса редактирования: смысл продукта
    /// в том, чтобы захват занимал секунду. Разбор всё равно произойдёт
    /// в приложении, там же можно и поправить.
    private func finish(with message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let hosting = UIHostingController(rootView: ShareConfirmationView(message: message))
            hosting.view.backgroundColor = .clear

            self.addChild(hosting)
            self.view.addSubview(hosting.view)
            hosting.view.frame = self.view.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hosting.didMove(toParent: self)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                self.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }
}

/// Подтверждение сохранения.
struct ShareConfirmationView: View {

    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.2))
    }
}
