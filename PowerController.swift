import Foundation

struct BatteryStatus {
    let onBattery: Bool
    let discharging: Bool
    let percent: Int
}

enum ToggleResult: Equatable {
    case ok
    case grantMissing
    case failed(String)
}

@MainActor
final class PowerController {
    func readSleepDisabled() -> Bool {
        let out = ShellRunner.capture("/usr/bin/pmset", ["-g"])
        for line in out.split(whereSeparator: { $0 == "\n" }) {
            if line.range(of: "SleepDisabled", options: .caseInsensitive) != nil {
                let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if let last = toks.last { return last == "1" }
            }
        }
        return false
    }

    func batteryStatus() -> BatteryStatus {
        let out = ShellRunner.capture("/usr/bin/pmset", ["-g", "batt"])
        let onBattery = out.contains("Battery Power")
        let discharging = out.range(of: "discharging", options: .caseInsensitive) != nil
        var percent = 100
        for tok in out.split(whereSeparator: { " \t\n;".contains($0) }) {
            if tok.hasSuffix("%"), let v = Int(tok.dropLast()) {
                percent = v
                break
            }
        }
        return BatteryStatus(onBattery: onBattery, discharging: discharging, percent: percent)
    }

    @discardableResult
    func setDisableSleep(_ on: Bool) -> ToggleResult {
        let res = ShellRunner.run(
            "/usr/bin/sudo",
            ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"],
            stdinNull: true
        )
        if res.exit == 0 { return .ok }
        if res.err.range(of: "a password is required", options: .caseInsensitive) != nil
            || res.err.range(of: "not allowed", options: .caseInsensitive) != nil
            || res.err.range(of: "may not run", options: .caseInsensitive) != nil {
            return .grantMissing
        }
        return .failed(res.err.isEmpty ? "exit \(res.exit)" : res.err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
