import Foundation
import RehabitCore
import Security
import SwiftUI

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

/// Refreshes every connected source by itself when the app comes to the
/// front, at most every two hours each: Apple Health (once the person has
/// connected it from Settings, so no permission prompt ever appears on its
/// own) and Garmin (recovery values and sessions: strength, runs, rides,
/// walks). The first refresh of a source looks back 90 days, later ones 14.
/// Reading the same day or session twice adds nothing. Each source runs on
/// its own, so one failing does not stop the other.
@MainActor
enum AutoRefresh {
    enum Source: String, CaseIterable {
        case health, garmin
        var title: String { self == .health ? "Apple Health" : "Garmin" }
    }

    static let interval: TimeInterval = 2 * 3600
    private static var running: Set<Source> = []
    static let healthConnectedKey = "health-connected"

    static func lastRun(_ source: Source) -> Date? { UserDefaults.standard.object(forKey: "auto-last-run-\(source.rawValue)") as? Date }
    static func lastResult(_ source: Source) -> String? { UserDefaults.standard.string(forKey: "auto-last-result-\(source.rawValue)") }

    /// "Last refreshed 20 minutes ago: 2 other activities added."
    static func statusLine(_ source: Source) -> String? {
        guard let result = lastResult(source) else { return nil }
        guard let last = lastRun(source) else { return result }
        return "Last refreshed \(last.formatted(.relative(presentation: .named))): \(result)"
    }

    private static func record(_ source: Source, _ text: String, ranAt: Date?) {
        if let ranAt { UserDefaults.standard.set(ranAt, forKey: "auto-last-run-\(source.rawValue)") }
        UserDefaults.standard.set(text, forKey: "auto-last-result-\(source.rawValue)")
    }

    static var healthConnected: Bool {
        get { UserDefaults.standard.bool(forKey: healthConnectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: healthConnectedKey) }
    }

    static func runIfDue(_ model: AppModel, now: Date = Date()) {
        guard !Demo.isRunning else { return }
        for source in Source.allCases where !running.contains(source) {
            if let last = lastRun(source), now.timeIntervalSince(last) < interval { continue }
            let days = lastRun(source) == nil ? 90 : 14
            switch source {
            case .health:
                guard healthConnected else { continue }
                running.insert(source)
                Task { @MainActor in
                    defer { running.remove(source) }
                    let count = await model.importHealth(from: HealthKitSource(), days: days)
                    if let count { record(source, count > 0 ? "\(count) daily values read." : "nothing new.", ranAt: now) }
                    else { record(source, "could not read Health: \(model.lastError ?? "not available").", ranAt: nil) }
                }
            case .garmin:
                guard let client = GarminAccount.client() else { continue }
                running.insert(source)
                Task { @MainActor in
                    defer { running.remove(source) }
                    let values = await model.importHealth(from: GarminSource(client: client), days: days)
                    let sessions = await model.importGarminWorkouts(from: client, days: days)
                    guard let sessions else {
                        record(source, "could not read Garmin: \(model.lastError ?? "no reason given").", ranAt: nil)
                        return
                    }
                    var parts: [String] = []
                    if sessions.workoutsAdded > 0 { parts.append(Format.count(sessions.workoutsAdded, "strength session")) }
                    if sessions.activitiesAdded > 0 {
                        parts.append("\(sessions.activitiesAdded) \(sessions.activitiesAdded == 1 ? "other activity" : "other activities")")
                    }
                    if let values, values > 0 { parts.append("\(values) daily values") }
                    record(source, parts.isEmpty ? "nothing new." : parts.joined(separator: ", ") + " added.", ranAt: now)
                }
            }
        }
    }
}
