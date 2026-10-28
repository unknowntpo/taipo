import Foundation

public enum UserDictionaryError: Error {
    case writeFailed(URL, underlying: Error)
}

/// Choices the user made, persisted as JSON at a caller-chosen path.
struct UserDictionary {
    struct Word: Codable, Equatable {
        let text: String
        let language: Language
        let keys: String
    }

    private struct File: Codable {
        var version = 1
        var choices: [String: String] = [:]
        var words: [Word] = []
    }

    let url: URL
    private var file = File()
    private(set) var diagnostics: [String] = []

    var choices: [String: String] { file.choices }
    var words: [Word] { file.words }

    init(url: URL) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let quarantine = url.appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: quarantine)
            diagnostics.append("user dictionary corrupt; moved to \(quarantine.lastPathComponent): \(error)")
        }
    }

    /// Updates memory first so the choice applies even when saving fails.
    mutating func record(input: String, chosen: String, newWord: Word?) throws {
        file.choices[input] = chosen
        if let newWord, !file.words.contains(newWord) { file.words.append(newWord) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            throw UserDictionaryError.writeFailed(url, underlying: error)
        }
    }
}

extension UserDictionary {
    /// Spec 010: memory only; the file is left to the caller.
    mutating func clear() { file = File() }

    /// Learned choices plus new words in the file at `url`; 0 when it is missing or unreadable.
    static func entryCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return 0 }
        return file.choices.count + file.words.count
    }
}

/// Reads a saved user dictionary without loading the lexicon (Spec 010).
public enum UserDictionaryFile {
    public static func entryCount(at url: URL) -> Int { UserDictionary.entryCount(at: url) }
}
