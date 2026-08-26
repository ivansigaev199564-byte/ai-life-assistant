import AuthenticationServices
import Foundation
import Observation
import Security

/// Вход через Apple и хранение сессии.
///
/// Sign in with Apple выбран не только ради удобства: он не требует
/// от пользователя ни почты, ни пароля, а приложению не нужно ничего
/// про него знать. Для продукта, который слушает личные заметки,
/// минимум данных о человеке это не мелочь, а свойство продукта.
@MainActor
@Observable
final class AuthService: NSObject {

    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn(userID: String)
        case failed(String)
    }

    private(set) var state: State = .signedOut

    /// Токен доступа для запросов к серверу. nil означает работу офлайн.
    private(set) var accessToken: String?

    private var refreshToken: String?
    private var expiresAt: Date?

    private let session: URLSession
    private var signInContinuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    /// Служба в Keychain, под которой хранится сессия.
    private static let keychainService = "com.ivans.ailifeassistant.session"

    init(session: URLSession = .shared) {
        self.session = session
        super.init()
        restoreSession()
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    // MARK: Вход

    /// Запускает системный диалог входа и обменивает результат на сессию.
    func signIn() async {
        guard SupabaseConfiguration.isConfigured else {
            state = .failed("Бэкенд не настроен")
            return
        }

        state = .signingIn

        do {
            let credential = try await requestAppleCredential()

            guard
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                state = .failed("Apple не вернул токен")
                return
            }

            try await exchange(identityToken: identityToken)
        } catch is CancellationError {
            state = .signedOut
        } catch {
            let nsError = error as NSError
            // Отмена пользователем это не ошибка: он просто передумал.
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue {
                state = .signedOut
                return
            }
            state = .failed(error.localizedDescription)
            Log.data.error("Вход не удался: \(error.localizedDescription)")
        }
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        expiresAt = nil
        deleteStoredSession()
        state = .signedOut
    }

    /// Обновляет токен, если он скоро истечёт.
    ///
    /// Вызывается перед синхронизацией: получить отказ по истёкшему токену
    /// посреди отправки данных хуже, чем потратить один лишний запрос.
    func refreshIfNeeded() async {
        guard let refreshToken, let expiresAt else { return }
        guard expiresAt.timeIntervalSinceNow < 300 else { return }

        do {
            try await refresh(using: refreshToken)
        } catch {
            Log.data.notice("Не удалось обновить сессию: \(error.localizedDescription)")
            signOut()
        }
    }
}

// MARK: - Системный диалог Apple

extension AuthService: ASAuthorizationControllerDelegate {

    private func requestAppleCredential() async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { continuation in
            signInContinuation = continuation

            let request = ASAuthorizationAppleIDProvider().createRequest()
            // Имя и почта запрашиваются один раз при первом входе.
            // Приложению они не нужны для работы, но без запроса Apple
            // не отдаст даже стабильный идентификатор пользователя.
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                signInContinuation?.resume(
                    throwing: NSError(
                        domain: "AuthService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Неожиданный тип учётных данных"]
                    )
                )
                signInContinuation = nil
                return
            }

            signInContinuation?.resume(returning: credential)
            signInContinuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            signInContinuation?.resume(throwing: error)
            signInContinuation = nil
        }
    }
}

// MARK: - Обмен токена

private extension AuthService {

    struct SessionResponse: Decodable {
        struct User: Decodable {
            let id: String
        }

        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let user: User

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case user
        }
    }

    /// Меняет токен Apple на сессию Supabase.
    func exchange(identityToken: String) async throws {
        guard let configuration = SupabaseConfiguration.current else {
            throw NSError(
                domain: "AuthService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Бэкенд не настроен"]
            )
        }

        var components = URLComponents(
            url: configuration.authURL.appendingPathComponent("token"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]

        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "apple",
            "id_token": identityToken
        ])

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "AuthService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Сервер отклонил вход: \(message)"]
            )
        }

        try store(try JSONDecoder().decode(SessionResponse.self, from: data))
    }

    /// Продлевает сессию по токену обновления.
    func refresh(using token: String) async throws {
        guard let configuration = SupabaseConfiguration.current else { return }

        var components = URLComponents(
            url: configuration.authURL.appendingPathComponent("token"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]

        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": token])

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(
                domain: "AuthService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Сессия не продлена"]
            )
        }

        try store(try JSONDecoder().decode(SessionResponse.self, from: data))
    }

    func store(_ response: SessionResponse) throws {
        accessToken = response.accessToken
        refreshToken = response.refreshToken
        expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        state = .signedIn(userID: response.user.id)

        saveSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: expiresAt ?? .now,
            userID: response.user.id
        )
    }
}

// MARK: - Хранение сессии

private extension AuthService {

    /// Сессия лежит в Keychain, а не в UserDefaults.
    ///
    /// Токен даёт доступ ко всем записям пользователя, включая траты
    /// и личные заметки. UserDefaults это обычный файл в контейнере
    /// приложения, а Keychain шифруется системой и защищён кодом устройства.
    struct StoredSession: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let userID: String
    }

    func saveSession(accessToken: String, refreshToken: String, expiresAt: Date, userID: String) {
        let stored = StoredSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            userID: userID
        )

        guard let data = try? JSONEncoder().encode(stored) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "session"
        ]

        // Сначала удаляем прежнюю запись: SecItemUpdate требует отдельной
        // ветки кода, а перезапись проще и не оставляет полусостояний.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // Токен нужен только после разблокировки и не уезжает в резервные
        // копии на другое устройство.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            Log.data.error("Сессия не сохранена в Keychain, код \(status)")
        }
    }

    func restoreSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "session",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            return
        }

        accessToken = stored.accessToken
        refreshToken = stored.refreshToken
        expiresAt = stored.expiresAt
        state = .signedIn(userID: stored.userID)

        // Просроченный токен не выбрасываем: обновление произойдёт
        // перед первой же синхронизацией, и пользователю не придётся
        // входить заново после недели без сети.
        if stored.expiresAt < .now {
            Task { await refreshIfNeeded() }
        }
    }

    func deleteStoredSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "session"
        ]
        SecItemDelete(query as CFDictionary)
    }
}
