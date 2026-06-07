import AppKit
import Darwin
import Foundation

enum AgentID: String, CaseIterable {
    case claude
    case codex
    case cursor

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var commandName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .cursor: return "cursor"
        }
    }
}

enum AgentStatus: String {
    case active = "Active"
    case idle = "Idle"
    case setupNeeded = "Setup needed"
}

struct AgentToolSnapshot {
    let id: AgentID
    let displayName: String
    let status: AgentStatus
    let detail: String
}

struct AgentSetupResult {
    let ok: Bool
    let message: String
    let logURL: URL
}

final class AgentMonitor {
    private let heartbeatFreshness: TimeInterval = 120
    private let heartbeatScriptVersion = "4"
    private let queue = DispatchQueue(label: "Sleepless.AgentMonitor", qos: .utility)
    private let fileManager = FileManager.default
    private var cachedCLIPaths: [String: String] = [:]
    private var cachedCursorInstalled: Bool?

    func snapshotsAsync(completion: @escaping ([AgentToolSnapshot]) -> Void) {
        queue.async {
            let snapshots = self.snapshots()
            DispatchQueue.main.async {
                completion(snapshots)
            }
        }
    }

    private func snapshots() -> [AgentToolSnapshot] {
        let processes = processList()
        return AgentID.allCases.compactMap { snapshot(for: $0, processes: processes) }
    }

    func installIntegration(for id: AgentID) -> AgentSetupResult {
        AppLogger.info("agent_setup_start", ["tool": id.rawValue])
        do {
            let script = try writeHeartbeatHelper()
            let installed: Bool
            switch id {
            case .claude:
                installed = try installClaudeHooks(script: script)
            case .codex:
                installed = try installCodexHooks(script: script)
            case .cursor:
                installed = try installCursorHooks(script: script)
            }
            guard installed else {
                let message = "Hook command was written but could not be verified in the tool config."
                AppLogger.error("agent_setup_verify_failed", ["tool": id.rawValue])
                return AgentSetupResult(ok: false, message: message, logURL: AppLogger.logURL)
            }
            let readme = heartbeatDirectory.appendingPathComponent("README.txt")
            let text = """
            Sleepless heartbeat helper

            Helper:
            \(script.path)

            Configure an app-wide hook in the agent tool to run this helper with the tool id:
            \(script.path) \(id.rawValue)

            Sleepless reads only these heartbeat files to decide whether local agent work is active.
            """
            try text.write(to: readme, atomically: true, encoding: .utf8)
            AppLogger.info("agent_setup_success", ["tool": id.rawValue])
            return AgentSetupResult(ok: true, message: "\(id.displayName) detector set up.", logURL: AppLogger.logURL)
        } catch {
            let nsError = error as NSError
            let message = setupErrorMessage(error)
            AppLogger.error("agent_setup_failed", [
                "tool": id.rawValue,
                "domain": nsError.domain,
                "code": String(nsError.code),
                "reason": message
            ])
            NSLog("Sleepless: agent integration setup failed: %@", message)
            return AgentSetupResult(ok: false, message: message, logURL: AppLogger.logURL)
        }
    }

    private func snapshot(for id: AgentID, processes: [ProcessSnapshot]) -> AgentToolSnapshot? {
        switch id {
        case .claude:
            guard let path = resolveCLI(command: "claude", extraPaths: [
                "\(home)/.local/bin/claude",
                "\(home)/.claude/local/bin/claude"
            ]) else { return nil }
            let status = statusFromIntegration(for: id)
            return AgentToolSnapshot(id: id, displayName: id.displayName, status: status, detail: path)

        case .codex:
            guard let path = resolveCLI(command: "codex", extraPaths: [
                "\(home)/.local/bin/codex"
            ]) else { return nil }
            let status = statusFromIntegration(for: id)
            return AgentToolSnapshot(id: id, displayName: id.displayName, status: status, detail: path)

        case .cursor:
            guard cursorInstalled() else { return nil }
            if heartbeatIsFresh(for: id) || cursorAgentProcessMatches(processes) {
                return AgentToolSnapshot(id: id, displayName: id.displayName, status: .active, detail: "Local agent signal")
            }
            let status: AgentStatus = integrationConfigured(for: id) ? .idle : .setupNeeded
            return AgentToolSnapshot(id: id, displayName: id.displayName, status: status, detail: "Cursor app installed")
        }
    }

    private func statusFromIntegration(for id: AgentID) -> AgentStatus {
        guard integrationConfigured(for: id) else { return .setupNeeded }
        return heartbeatIsFresh(for: id) ? .active : .idle
    }

    private func resolveCLI(command: String, extraPaths: [String]) -> String? {
        if let cached = cachedCLIPaths[command] { return cached }

        let candidates = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)",
            "/bin/\(command)"
        ] + extraPaths

        for path in candidates where isExecutable(path) && validates(commandAt: path) {
            cachedCLIPaths[command] = path
            return path
        }

        let shell = ShellRunner.run("/bin/zsh", ["-lc", "command -v \(command)"], timeout: 2)
        let path = shell.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shell.exit == 0, !path.isEmpty, isExecutable(path), validates(commandAt: path) else {
            return nil
        }
        cachedCLIPaths[command] = path
        return path
    }

    private func validates(commandAt path: String) -> Bool {
        ShellRunner.run(path, ["--version"], timeout: 2).exit == 0
    }

    private func isExecutable(_ path: String) -> Bool {
        fileManager.isExecutableFile(atPath: NSString(string: path).expandingTildeInPath)
    }

    private func cursorInstalled() -> Bool {
        if let cachedCursorInstalled { return cachedCursorInstalled }
        let workspace = NSWorkspace.shared
        let installed = workspace.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") != nil
            || workspace.urlForApplication(withBundleIdentifier: "co.anysphere.cursor.nightly") != nil
        cachedCursorInstalled = installed
        return installed
    }

    private func cursorAgentProcessMatches(_ processes: [ProcessSnapshot]) -> Bool {
        processes.contains { proc in
            guard proc.uid == getuid() else { return false }
            return proc.command == "cursor-agent"
                || proc.command == "cursor-agent-worker"
        }
    }

    private func heartbeatIsFresh(for id: AgentID) -> Bool {
        let url = heartbeatURL(for: id)
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else {
            return false
        }
        guard heartbeatFile(at: url, belongsTo: id) else { return false }
        return Date().timeIntervalSince(modified) <= heartbeatFreshness
    }

    private func heartbeatFile(at url: URL, belongsTo id: AgentID) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        var fields: [String: String] = [:]
        text.split(whereSeparator: \.isNewline).forEach { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            fields[String(parts[0])] = String(parts[1])
        }
        guard fields["version"] == heartbeatScriptVersion,
              fields["tool"] == id.rawValue,
              fields["state"] == "active",
              let timestamp = fields["time"].flatMap(TimeInterval.init) else {
            return false
        }
        if id != .cursor, heartbeatOriginIsCursor(fields["process_chain"] ?? "") {
            return false
        }
        return Date().timeIntervalSince1970 - timestamp <= heartbeatFreshness
    }

    private func heartbeatOriginIsCursor(_ processChain: String) -> Bool {
        processChain
            .lowercased()
            .split(separator: "|")
            .contains { part in
                let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                return name == "cursor" || name.hasPrefix("cursor ") || name.contains("/cursor")
            }
    }

    private func integrationConfigured(for id: AgentID) -> Bool {
        do {
            let root = try readJSONObject(at: configURL(for: id))
            guard let hooks = root["hooks"] as? [String: Any] else { return false }
            let configured = expectedEvents(for: id, script: heartbeatDirectory.appendingPathComponent("heartbeat.sh")).allSatisfy { event in
                guard let entries = hooks[event.name] as? [[String: Any]] else { return false }
                return entries.contains { hookEntry($0, contains: event.command, nestedCommandSchema: usesNestedHookSchema(id)) }
            }
            guard configured else { return false }
            if !heartbeatHelperIsCurrent() {
                _ = try writeHeartbeatHelper()
            }
            return true
        } catch {
            AppLogger.error("agent_setup_structural_verify_failed", [
                "tool": id.rawValue,
                "reason": error.localizedDescription
            ])
            return false
        }
    }

    private func installClaudeHooks(script: URL) throws -> Bool {
        let url = configURL(for: .claude)
        AppLogger.info("agent_setup_merge_config", ["tool": AgentID.claude.rawValue, "path": url.path])
        let events = expectedEvents(for: .claude, script: script)
        try mergeCommandHooks(
            into: url,
            events: events,
            nestedCommandSchema: true,
            versioned: false
        )
        return integrationConfigured(for: .claude)
    }

    private func installCodexHooks(script: URL) throws -> Bool {
        let url = configURL(for: .codex)
        AppLogger.info("agent_setup_merge_config", ["tool": AgentID.codex.rawValue, "path": url.path])
        let events = expectedEvents(for: .codex, script: script)
        try mergeCommandHooks(
            into: url,
            events: events,
            nestedCommandSchema: true,
            versioned: false
        )
        return integrationConfigured(for: .codex)
    }

    private func installCursorHooks(script: URL) throws -> Bool {
        let url = configURL(for: .cursor)
        AppLogger.info("agent_setup_merge_config", ["tool": AgentID.cursor.rawValue, "path": url.path])
        let events = expectedEvents(for: .cursor, script: script)
        try mergeCommandHooks(
            into: url,
            events: events,
            nestedCommandSchema: false,
            versioned: true
        )
        return integrationConfigured(for: .cursor)
    }

    private func mergeCommandHooks(into url: URL, events: [HookEvent], nestedCommandSchema: Bool, versioned: Bool) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root = try readJSONObject(at: url)
        if versioned, root["version"] == nil { root["version"] = 1 }
        var hooks: [String: Any]
        if let existing = root["hooks"] {
            if let typed = existing as? [String: Any] {
                hooks = typed
            } else {
                let backup = backupInvalidConfig(at: url)
                AppLogger.error("agent_setup_invalid_hooks_shape_replaced", ["path": url.path, "backup": backup.path])
                root = versioned ? ["version": 1] : [:]
                hooks = [:]
            }
        } else {
            hooks = [:]
        }
        hooks = pruneSleeplessHooks(from: hooks, nestedCommandSchema: nestedCommandSchema)

        for event in events {
            var entries: [[String: Any]]
            if let existing = hooks[event.name] {
                if let typed = existing as? [[String: Any]] {
                    entries = typed
                } else {
                    let backup = backupInvalidConfig(at: url)
                    AppLogger.error("agent_setup_invalid_event_shape_replaced", [
                        "path": url.path,
                        "backup": backup.path,
                        "event": event.name
                    ])
                    root = versioned ? ["version": 1] : [:]
                    hooks = [:]
                    entries = []
                }
            } else {
                entries = []
            }
            let alreadyInstalled = entries.contains { hookEntry($0, contains: event.command, nestedCommandSchema: nestedCommandSchema) }
            guard !alreadyInstalled else { continue }

            if nestedCommandSchema {
                var entry: [String: Any] = [
                    "hooks": [
                        [
                            "type": "command",
                            "command": event.command
                        ]
                    ]
                ]
                if let matcher = event.matcher { entry["matcher"] = matcher }
                entries.append(entry)
            } else {
                entries.append(["command": event.command])
            }
            hooks[event.name] = entries
        }

        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func configURL(for id: AgentID) -> URL {
        switch id {
        case .claude:
            return homeURL.appendingPathComponent(".claude/settings.json")
        case .codex:
            return homeURL.appendingPathComponent(".codex/hooks.json")
        case .cursor:
            return homeURL.appendingPathComponent(".cursor/hooks.json")
        }
    }

    private func usesNestedHookSchema(_ id: AgentID) -> Bool {
        id == .claude || id == .codex
    }

    private func expectedEvents(for id: AgentID, script: URL) -> [HookEvent] {
        switch id {
        case .claude:
            return [
                HookEvent(name: "UserPromptSubmit", command: heartbeatCommand(script: script, tool: .claude, state: "active"), matcher: nil, state: "active"),
                HookEvent(name: "PreToolUse", command: heartbeatCommand(script: script, tool: .claude, state: "active"), matcher: ".*", state: "active"),
                HookEvent(name: "PostToolUse", command: heartbeatCommand(script: script, tool: .claude, state: "active"), matcher: ".*", state: "active"),
                HookEvent(name: "Stop", command: heartbeatCommand(script: script, tool: .claude, state: "stop"), matcher: nil, state: "stop")
            ]
        case .codex:
            return [
                HookEvent(name: "UserPromptSubmit", command: heartbeatCommand(script: script, tool: .codex, state: "active"), matcher: nil, state: "active"),
                HookEvent(name: "PreToolUse", command: heartbeatCommand(script: script, tool: .codex, state: "active"), matcher: ".*", state: "active"),
                HookEvent(name: "PostToolUse", command: heartbeatCommand(script: script, tool: .codex, state: "active"), matcher: ".*", state: "active"),
                HookEvent(name: "Stop", command: heartbeatCommand(script: script, tool: .codex, state: "stop"), matcher: nil, state: "stop")
            ]
        case .cursor:
            return [
                HookEvent(name: "beforeSubmitPrompt", command: heartbeatCommand(script: script, tool: .cursor, state: "active"), matcher: nil, state: "active"),
                HookEvent(name: "preToolUse", command: heartbeatCommand(script: script, tool: .cursor, state: "active"), matcher: nil, state: "active"),
                HookEvent(name: "postToolUse", command: heartbeatCommand(script: script, tool: .cursor, state: "active"), matcher: nil, state: "active"),
                HookEvent(name: "stop", command: heartbeatCommand(script: script, tool: .cursor, state: "stop"), matcher: nil, state: "stop")
            ]
        }
    }

    private func hookEntry(_ entry: [String: Any], contains command: String, nestedCommandSchema: Bool) -> Bool {
        if nestedCommandSchema {
            guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
            return hooks.contains { ($0["command"] as? String) == command }
        }
        return (entry["command"] as? String) == command
    }

    private func pruneSleeplessHooks(from hooks: [String: Any], nestedCommandSchema: Bool) -> [String: Any] {
        var pruned = hooks
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.compactMap { pruneSleeplessHookEntry($0, nestedCommandSchema: nestedCommandSchema) }
            if kept.isEmpty {
                pruned.removeValue(forKey: event)
            } else {
                pruned[event] = kept
            }
        }
        return pruned
    }

    private func pruneSleeplessHookEntry(_ entry: [String: Any], nestedCommandSchema: Bool) -> [String: Any]? {
        if !nestedCommandSchema {
            return commandOwnedBySleepless(entry["command"]) ? nil : entry
        }

        guard let hooks = entry["hooks"] as? [[String: Any]] else { return entry }
        let keptHooks = hooks.filter { !commandOwnedBySleepless($0["command"]) }
        guard keptHooks.count != hooks.count else { return entry }
        guard !keptHooks.isEmpty else { return nil }
        var updated = entry
        updated["hooks"] = keptHooks
        return updated
    }

    private func commandOwnedBySleepless(_ command: Any?) -> Bool {
        guard let command = command as? String else { return false }
        return command.contains(".sleepless/agents/heartbeat.sh")
    }

    private func readJSONObject(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            let backup = backupInvalidConfig(at: url)
            AppLogger.error("agent_setup_invalid_json_replaced", ["path": url.path, "backup": backup.path])
            return [:]
        }
        guard let object = parsed as? [String: Any] else {
            let backup = backupInvalidConfig(at: url)
            AppLogger.error("agent_setup_invalid_top_level_replaced", ["path": url.path, "backup": backup.path])
            return [:]
        }
        return object
    }

    private func backupInvalidConfig(at url: URL) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".sleepless-backup-\(stamp)")
        try? fileManager.copyItem(at: url, to: backup)
        return backup
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func heartbeatCommand(for id: AgentID, state: String) -> String {
        heartbeatCommand(script: heartbeatDirectory.appendingPathComponent("heartbeat.sh"), tool: id, state: state)
    }

    private func heartbeatCommand(script: URL, tool: AgentID, state: String) -> String {
        "\(shellQuoted(script.path)) \(tool.rawValue) \(state)"
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func processList() -> [ProcessSnapshot] {
        let out = ShellRunner.capture("/bin/ps", ["-axo", "pid=,uid=,comm="], timeout: 2)
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let uid = uid_t(String(parts[1])) else { return nil }
            return ProcessSnapshot(
                pid: pid,
                uid: uid,
                executablePath: String(parts[2])
            )
        }
    }

    private var home: String { homeURL.path }
    private var homeURL: URL { fileManager.homeDirectoryForCurrentUser }
    private var heartbeatDirectory: URL { homeURL.appendingPathComponent(".sleepless/agents", isDirectory: true) }
    private func heartbeatURL(for id: AgentID) -> URL { heartbeatDirectory.appendingPathComponent("\(id.rawValue).heartbeat") }

    private func writeHeartbeatHelper() throws -> URL {
        try fileManager.createDirectory(at: heartbeatDirectory, withIntermediateDirectories: true)
        let script = heartbeatDirectory.appendingPathComponent("heartbeat.sh")
        AppLogger.info("agent_setup_write_helper", ["path": script.path, "version": heartbeatScriptVersion])
        try heartbeatHelperBody.write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        AgentID.allCases.forEach { try? fileManager.removeItem(at: heartbeatURL(for: $0)) }
        return script
    }

    private func heartbeatHelperIsCurrent() -> Bool {
        let script = heartbeatDirectory.appendingPathComponent("heartbeat.sh")
        guard fileManager.isExecutableFile(atPath: script.path),
              let data = try? Data(contentsOf: script),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.contains("SLEEPLESS_HEARTBEAT_VERSION=\(heartbeatScriptVersion)")
    }

    private var heartbeatHelperBody: String {
        """
        #!/bin/zsh
        set -eu
        SLEEPLESS_HEARTBEAT_VERSION=\(heartbeatScriptVersion)
        tool="${1:-unknown}"
        state="${2:-active}"
        case "$tool" in
          claude|codex|cursor) ;;
          *) exit 0 ;;
        esac
        dir="$HOME/.sleepless/agents"
        mkdir -p "$dir"
        process_chain=""
        pid="$$"
        while [ -n "$pid" ] && [ "$pid" != "0" ]; do
          comm="$(/bin/ps -o comm= -p "$pid" 2>/dev/null || true)"
          [ -n "$comm" ] && process_chain="${process_chain:+$process_chain|}$comm"
          pid="$(/bin/ps -o ppid= -p "$pid" 2>/dev/null | /usr/bin/tr -d ' ' || true)"
        done
        write_heartbeat() {
          tmp="$dir/$tool.heartbeat.tmp"
          {
            /bin/echo "version=$SLEEPLESS_HEARTBEAT_VERSION"
            /bin/echo "tool=$tool"
            /bin/echo "state=$state"
            /bin/echo "time=$(/bin/date +%s)"
            /bin/echo "process_chain=$process_chain"
          } > "$tmp"
          /bin/mv "$tmp" "$dir/$tool.heartbeat"
        }
        case "$state" in
          stop) state="stop"; write_heartbeat ;;
          *) state="active"; write_heartbeat ;;
        esac
        """
    }

    private func setupErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return "Permission denied while writing the agent hook config."
        case NSFileWriteFileExistsError:
            return "A file already exists where a setup directory is needed."
        default:
            return error.localizedDescription
        }
    }
}

private struct ProcessSnapshot {
    let pid: Int32
    let uid: uid_t
    let executablePath: String

    var command: String {
        URL(fileURLWithPath: executablePath).lastPathComponent
    }
}

private struct HookEvent {
    let name: String
    let command: String
    let matcher: String?
    let state: String
}
