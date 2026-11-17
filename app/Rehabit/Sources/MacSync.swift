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
    private var checkStarted: Date?

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

    /// Looks for inbox files (`rehabit-inbox*.json`) in the chosen folder, and
    /// in its Rehabit folder when the top of iCloud Drive was chosen, and offers
    /// the newest that would add anything. The files are often not on the phone
    /// yet, or not in their newest version, so each is brought down from iCloud
    /// (waiting up to 30 seconds) and read off the main thread. Nothing found,
    /// nothing said.
    func checkInbox(_ model: AppModel) {
        // A read stuck on iCloud must not block every later check.
        if checking, let started = checkStarted, Date().timeIntervalSince(started) < 90 { return }
        guard isSetUp, let folder = try? resolveFolder() else { return }
        checking = true
        checkStarted = Date()
        var folders = [folder]
        if folder.lastPathComponent == "com~apple~CloudDocs" { folders.append(folder.appendingPathComponent("Rehabit")) }
        Task.detached(priority: .utility) {
            let files = Self.readInboxes(in: folders, scope: folder, deadline: Date().addingTimeInterval(75))
            await MainActor.run {
                defer { self.checking = false; self.checkStarted = nil }
                for data in files where self.offer(data, model: model) && self.inbox != nil { return }
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

    /// Every inbox file in the folders, newest first, as read once it is current.
    nonisolated private static func readInboxes(in folders: [URL], scope: URL, deadline: Date) -> [Data] {
        let access = scope.startAccessingSecurityScopedResource()
        defer { if access { scope.stopAccessingSecurityScopedResource() } }
        var out: [Data] = []
        for folder in folders {
            let listing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in InboxFiles.names(in: listing) where Date() < deadline {
                if let data = readCurrent(folder.appendingPathComponent(name), deadline: deadline) { out.append(data) }
            }
        }
        return out
    }

    /// Asks iCloud for the newest version and waits (up to 30 seconds, and not
    /// past the deadline) until it is on the phone, then reads it coordinated.
    nonisolated private static func readCurrent(_ url: URL, deadline: Date) -> Data? {
        let until = min(deadline, Date().addingTimeInterval(30))
        var target = url
        func status() -> URLUbiquitousItemDownloadingStatus? {
            target.removeAllCachedResourceValues()
            return try? target.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        }
        // A file not on the phone yet has no status under its own name; ask for it all the same.
        if status() != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            while Date() < until, status() != .current { Thread.sleep(forTimeInterval: 1) }
        }
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readable in
            result = try? Data(contentsOf: readable)
        }
        return result
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
