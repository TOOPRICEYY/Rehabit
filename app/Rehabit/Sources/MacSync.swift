import Foundation
import Observation
import RehabitCore

/// Leaves the app's export in a folder the person chose once (the "Rehabit"
/// folder in iCloud Drive), where the Mac picks it up and rebuilds the data
/// Claude reads. Written after a workout is finished, a pain check answered,
/// an injury saved or an import run, a few seconds after the last change.
///
/// The folder is kept as a security-scoped bookmark, which needs no iCloud
/// entitlement. Nothing leaves the phone except through iCloud Drive.
@MainActor
@Observable
final class MacSync {
    static let shared = MacSync()
    static let fileName = "rehabit-export.json"
    private static let bookmarkKey = "macSync.folderBookmark"
    private static let lastSyncKey = "macSync.lastSync"

    private(set) var folderName: String?
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var busy = false
    private var pending: Task<Void, Never>?

    private init() {
        lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        folderName = (try? resolveFolder())?.lastPathComponent
    }

    var isSetUp: Bool { UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil }

    /// Remembers a folder picked in the Files sheet, then writes to it straight away.
    func choose(_ folder: URL, model: AppModel) {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            folderName = folder.lastPathComponent
            lastError = nil
            syncNow(model)
        } catch {
            lastError = "That folder could not be remembered: \(error.localizedDescription)"
        }
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        folderName = nil
    }

    /// Called when stored records changed. Waits a few seconds so a burst of
    /// changes (finishing a workout schedules several checks) writes once.
    func changed(_ model: AppModel) {
        guard isSetUp else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.syncNow(model)
        }
    }

    func syncNow(_ model: AppModel) {
        pending?.cancel()
        guard let data = model.exportJSON() else {
            lastError = "The export could not be prepared."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let folder = try resolveFolder()
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            try Self.write(data, to: folder.appendingPathComponent(Self.fileName))
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: Self.lastSyncKey)
            lastError = nil
        } catch {
            lastError = "Could not write to the folder: \(error.localizedDescription)"
        }
    }

    private func resolveFolder() throws -> URL {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        return url
    }

    /// A coordinated, atomic replace, so iCloud and the Mac never see half a file.
    static func write(_ data: Data, to file: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
}
