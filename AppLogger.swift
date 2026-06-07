import Foundation

enum AppLogger {
    private static let subsystem = "SleeplessAgents"
    private static let maxBytes = 256 * 1024
    private static let queue = DispatchQueue(label: "SleeplessAgents.AppLogger", qos: .utility)
    private static let fileManager = FileManager.default

    static var logURL: URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return base
            .appendingPathComponent("com.aboudjem.Sleepless", isDirectory: true)
            .appendingPathComponent("setup-diagnostics.jsonl")
    }

    static func info(_ event: String, _ fields: [String: String] = [:]) {
        write(level: "INFO", event: event, fields: fields)
    }

    static func error(_ event: String, _ fields: [String: String] = [:]) {
        write(level: "ERROR", event: event, fields: fields)
    }

    private static func write(level: String, event: String, fields: [String: String]) {
        queue.async {
            var object: [String: Any] = [
                "ts": ISO8601DateFormatter().string(from: Date()),
                "level": level.lowercased(),
                "event": event,
                "pid": Int(ProcessInfo.processInfo.processIdentifier)
            ]
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                object["appVersion"] = version
            }
            if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                object["build"] = build
            }
            for (key, value) in fields {
                object[key] = redact(value)
            }
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                NSLog("%@: failed to encode log event %@", subsystem, event)
                return
            }
            let encoded = String(decoding: data, as: UTF8.self)
            let line = String(encoded.prefix(4096)) + "\n"
            append(line)
        }
    }

    private static func append(_ line: String) {
        let url = logURL
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            rotateIfNeeded(url)
            let data = Data(line.utf8)
            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            NSLog("%@: failed to write log: %@", subsystem, error.localizedDescription)
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maxBytes else {
            return
        }
        let archive = url.deletingLastPathComponent().appendingPathComponent("setup-diagnostics.jsonl.1")
        try? fileManager.removeItem(at: archive)
        try? fileManager.moveItem(at: url, to: archive)
    }

    private static func redact(_ value: String) -> String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return value.replacingOccurrences(of: home, with: "~")
    }
}
