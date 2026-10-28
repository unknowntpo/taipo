import Foundation
import TaipoCore

/// Where the learned choices live and how they are cleared (Spec 010).
public enum UserDictionaryStore {
    /// Posted (distributed) after a clear so the running input method forgets what it holds in memory.
    public static let cleared = Notification.Name("com.unknowntpo.inputmethod.Taipo.userDictionaryCleared")

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Taipo/user.json")
    }

    public static func entryCount(at url: URL = defaultURL) -> Int {
        UserDictionaryFile.entryCount(at: url)
    }

    /// Removes the file (by default to the Trash, so it can be recovered), then notifies.
    /// Returns false when there was no file; the notification is still sent. A failed removal
    /// throws before anything is posted.
    @discardableResult
    public static func clear(at url: URL = defaultURL,
                             remove: (URL) throws -> Void = moveToTrash,
                             notify: () -> Void = postCleared) throws -> Bool {
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists { try remove(url) }
        notify()
        return exists
    }

    public static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public static func postCleared() {
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(cleared, object: nil, deliverImmediately: true)
        #endif
    }
}
