// LidMonitor.swift — observe the laptop lid (clamshell) open/close state.
//
// Sleepless keeps the *system* awake with the lid closed (pmset disablesleep), but
// system sleep and DISPLAY sleep are independent: disablesleep never touches the
// display. macOS normally blanks the internal panel when the lid is shut (the
// clamshell sensor drives WindowServer), so the screen draws ~no power. This monitor
// makes that behaviour explicit and guaranteed: it watches for the lid closing and
// lets the app immediately put the display(s) to sleep, closing the edge-case window
// where a stray display assertion could otherwise keep the backlight lit and drain
// the battery while the Mac runs headless in the bag.
//
// Mechanism: IOPMrootDomain delivers kIOPMMessageClamshellStateChange as a general
// interest notification. We subscribe directly to that service, read the authoritative
// "AppleClamshellState" property on each notification, and fire a callback on
// open<->closed transitions.
//
// No daemon, no persisted state, no extra privilege: the port is reclaimed when the
// process exits, matching the rest of the app's "reboot resets everything" model.
import Foundation
import IOKit
import IOKit.pwr_mgt

// IOKit message IDs. kIOPMMessageClamshellStateChange is a C macro:
// iokit_family_msg(sub_iokit_powermanagement, 0x100).
private let kMsgClamshellStateChange: UInt32 = 0xE003_4100

@MainActor
final class LidMonitor {
    /// Fired when the lid transitions to CLOSED.
    var onLidClosed: (() -> Void)?
    /// Fired when the lid transitions to OPEN.
    var onLidOpened: (() -> Void)?

    private var rootDomain: io_service_t = 0
    private var notifierObject: io_object_t = 0
    private var notifyPort: IONotificationPortRef?
    private var lastClosed = false
    private var started = false

    func start() {
        guard !started else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            IONotificationPortDestroy(port)
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var notifier: io_object_t = 0
        let result = "IOGeneralInterest".withCString { interest in
            IOServiceAddInterestNotification(port, service, interest, { refcon, _, messageType, _ in
                guard let refcon else { return }
                let monitor = Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated {
                    monitor.handle(messageType: messageType)
                }
            }, refcon, &notifier)
        }
        guard result == KERN_SUCCESS else {
            IOObjectRelease(service)
            IONotificationPortDestroy(port)
            return
        }

        lastClosed = Self.readClamshellClosed()
        rootDomain = service
        notifierObject = notifier
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .commonModes)
        started = true
    }

    func stop() {
        guard started else { return }
        if let port = notifyPort {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                                  .commonModes)
        }
        if notifierObject != 0 { IOObjectRelease(notifierObject) }
        if rootDomain != 0 { IOObjectRelease(rootDomain) }
        if let port = notifyPort { IONotificationPortDestroy(port) }
        notifyPort = nil
        notifierObject = 0
        rootDomain = 0
        started = false
    }

    private func handle(messageType: UInt32) {
        guard messageType == kMsgClamshellStateChange else { return }
        let closed = Self.readClamshellClosed()
        guard closed != lastClosed else { return }
        lastClosed = closed
        if closed { onLidClosed?() } else { onLidOpened?() }
    }

    /// True when the lid is shut. Reads IOPMrootDomain's "AppleClamshellState"
    /// (Yes = closed, No/absent = open). No root required.
    static func readClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                       kCFAllocatorDefault, 0) else { return false }
        return (cf.takeRetainedValue() as? Bool) ?? false
    }
}
