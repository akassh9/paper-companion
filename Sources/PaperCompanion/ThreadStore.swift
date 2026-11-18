import Foundation
import CryptoKit

/// Saves threads per PDF, keyed by a hash of the file's bytes, in
/// ~/Library/Application Support/Paper Companion/Threads/<hash>.json
enum ThreadStore {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Paper Companion/Threads", isDirectory: true)
    }

    static func key(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func load(key: String) -> PaperArchive? {
        let url = folder.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PaperArchive.self, from: data)
    }

    static func save(_ archive: PaperArchive, key: String) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(archive)
            try data.write(to: folder.appendingPathComponent("\(key).json"), options: .atomic)
        } catch {
            NSLog("Paper Companion: couldn't save threads: \(error)")
        }
    }
}
