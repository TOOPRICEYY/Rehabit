import Foundation

/// Which files in a folder are inboxes of records prepared on the Mac.
///
/// Each inbox is written under a new name (`rehabit-inbox-20261117-183000.json`),
/// because iCloud brings a new name to the phone as a fresh placeholder, while a
/// changed file under an old name can sit on the phone as the stale copy for a
/// while. The plain `rehabit-inbox.json` of earlier builds is still read.
public enum InboxFiles {
    public static let prefix = "rehabit-inbox"
    public static let plain = "rehabit-inbox.json"

    /// The inbox file names in a folder listing, newest first. A file iCloud has
    /// not brought down yet is listed as `.name.json.icloud` and counts as the
    /// file itself. Timestamped names sort by their time; the plain name is
    /// treated as the oldest.
    public static func names(in listing: [String]) -> [String] {
        var found = Set<String>()
        for entry in listing {
            var name = entry
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
            }
            guard name.hasPrefix(prefix), name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            let middle = name.dropFirst(prefix.count).dropLast(".json".count)
            guard middle.isEmpty || middle.first == "-" else { continue }      // not "rehabit-inboxes.json"
            found.insert(name)
        }
        return found.sorted { a, b in
            if a == plain { return false }
            if b == plain { return true }
            return a > b
        }
    }

    /// A name for a new inbox written at `date`, e.g. `rehabit-inbox-20261117-183000.json`.
    public static func name(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(prefix)-\(f.string(from: date)).json"
    }
}
