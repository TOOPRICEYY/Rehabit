import Foundation
import RehabitCore
import Security

/// The network for Garmin, on URLSession. Nothing is cached or stored: the
/// answers hold health data and the requests hold a token.
struct URLSessionTransport: HTTPTransport {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private func send(_ method: String, _ url: String, _ headers: [String: String]) async throws -> HTTPReply {
        guard let address = URL(string: url) else { throw GarminError(description: "Bad address.") }
        var request = URLRequest(url: address)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSessionTransport.session.data(for: request)
        return HTTPReply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    func get(_ url: String, headers: [String: String]) async throws -> HTTPReply { try await send("GET", url, headers) }
    func post(_ url: String, headers: [String: String]) async throws -> HTTPReply { try await send("POST", url, headers) }
}

/// One secret in the iPhone's Keychain: encrypted by the system, readable only
/// by this app while the phone is unlocked, and left out of backups to other devices.
enum Keychain {
    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.gabrielprice.rehabit",
         kSecAttrAccount as String: name]
    }

    static func read(_ name: String) -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ name: String, _ value: String) -> Bool {
        SecItemDelete(query(name) as CFDictionary)
        var q = query(name)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ name: String) { SecItemDelete(query(name) as CFDictionary) }
}

enum GarminAccount {
    static let keyName = "garmin-personal-api-key"
    static var isConnected: Bool { Keychain.read(keyName) != nil }
    static func client() -> GarminClient? {
        Keychain.read(keyName).map { GarminClient(apiKey: $0, transport: URLSessionTransport()) }
    }
}
