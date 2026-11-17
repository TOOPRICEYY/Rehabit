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
    /// Records prepared on the Mac (by Claude, say) for the app to take in,
    /// after the person has looked at them.
    static let inboxName = "rehabit-inbox.json"
    private static let bookmarkKey = "macSync.folderBookmark"
    private static let lastSyncKey = "macSync.lastSync"

    private(set) var folderName: String?
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var busy = false
    private var pending: Task<Void, Never>?
    /// What the inbox file would add, when it would add anything.
    private(set) var inbox: IncomingRecords?
    private var inboxData: Data?
    private var checking = false

    private init() {
        lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        folderName = (try? resolveFolder()).map(Self.displayName)
    }

    var isSetUp: Bool { UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil }

    /// Remembers a folder picked in the Files sheet, then writes to it straight away.
    func choose(_ folder: URL, model: AppModel) {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            folderName = Self.displayName(folder)
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
            checkInbox(model)
        } catch {
            lastError = "Could not write to the folder: \(error.localizedDescription)"
        }
    }

    // MARK: Inbox

    /// Looks for the inbox file in the chosen folder (and in its Rehabit folder
    /// when the top of iCloud Drive was chosen). The file is often not on the
    /// phone yet, so it is downloaded and read off the main thread. A missing
    /// or unreadable file says nothing.
    func checkInbox(_ model: AppModel) {
        guard isSetUp, !checking, let folder = try? resolveFolder() else { return }
        checking = true
        var candidates = [folder.appendingPathComponent(Self.inboxName)]
        if folder.lastPathComponent == "com~apple~CloudDocs" {
            candidates.append(folder.appendingPathComponent("Rehabit").appendingPathComponent(Self.inboxName))
        }
        Task.detached(priority: .utility) {
            let data = Self.read(candidates, in: folder)
            await MainActor.run {
                self.checking = false
                self.offer(data, model: model)
            }
        }
    }

    /// Shows what a file would add, for review. Used by the inbox and by a
    /// file picked in Settings. Returns false if the file is not Rehabit records.
    @discardableResult
    func offer(_ data: Data?, model: AppModel) -> Bool {
        guard let data, let records = try? model.incoming(data) else { return false }
        inbox = records.isEmpty ? nil : records
        inboxData = records.isEmpty ? nil : data
        return true
    }

    /// Stores what was offered, once the person said so, and writes a fresh
    /// export so the Mac sees it too. The file is left where it is: taken in,
    /// it has nothing more to offer.
    func takeInbox(_ model: AppModel) {
        guard let data = inboxData else { return }
        model.takeIn(data)
        inbox = nil
        inboxData = nil
        if isSetUp { syncNow(model) }
    }

    func dismissInbox() {
        inbox = nil
        inboxData = nil
    }

    nonisolated private static func read(_ candidates: [URL], in folder: URL) -> Data? {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        for url in candidates {
            // An iCloud file not yet on the phone shows up only as a placeholder.
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            guard FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path)
            else { continue }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            var result: Data?
            var error: NSError?
            // A coordinated read waits for iCloud to bring the file down.
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readable in
                result = try? Data(contentsOf: readable)
            }
            if let result { return result }
        }
        return nil
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

    /// The folder's name as Files shows it: the top of iCloud Drive is stored
    /// as "com~apple~CloudDocs", which means nothing to anyone.
    static func displayName(_ folder: URL) -> String {
        let name = folder.lastPathComponent
        if name == "com~apple~CloudDocs" { return "iCloud Drive" }
        if folder.deletingLastPathComponent().lastPathComponent == "com~apple~CloudDocs" { return "iCloud Drive › \(name)" }
        return name
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
