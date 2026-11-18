// USBDeviceWatcher — says the moment an Apple USB device leaves or comes back.
//
// ChainManager's 3s `ios list` poll misses a reset shorter than one poll, and
// those still kill a phone's forwards. IOKit reports every one. Devices are
// named by their USB serial number, which is the phone's UDID without its dash
// (see usbSerial(_:matchesUDID:)). Keyboards and displays from Apple show up
// too; ChainManager ignores any serial that is not one of its phones.
//
// Main thread only.

import Foundation
import IOKit

final class USBDeviceWatcher {
    var onDetached: ((_ serial: String) -> Void)?
    var onAttached: ((_ serial: String) -> Void)?

    private var port: IONotificationPortRef?
    private var matchedIter: io_iterator_t = 0
    private var terminatedIter: io_iterator_t = 0
    /// Registry entry id → serial, saved on arrival: a terminated entry may
    /// no longer answer property reads.
    private var serials: [UInt64: String] = [:]

    /// Serials of the Apple USB devices plugged in now. Discovery uses it to
    /// tell USB phones apart when `ios list --details` fails.
    var presentSerials: Set<String> { Set(serials.values) }

    deinit { stop() }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, Self.appleUSBDevices(), { ctx, iter in
            guard let ctx else { return }
            Unmanaged<USBDeviceWatcher>.fromOpaque(ctx).takeUnretainedValue()
                .drain(iter, arrived: true, notify: true)
        }, me, &matchedIter)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, Self.appleUSBDevices(), { ctx, iter in
            guard let ctx else { return }
            Unmanaged<USBDeviceWatcher>.fromOpaque(ctx).takeUnretainedValue()
                .drain(iter, arrived: false, notify: true)
        }, me, &terminatedIter)
        // Draining arms each notification. Phones already here are not news.
        drain(matchedIter, arrived: true, notify: false)
        drain(terminatedIter, arrived: false, notify: false)
    }

    func stop() {
        if matchedIter != 0 { IOObjectRelease(matchedIter); matchedIter = 0 }
        if terminatedIter != 0 { IOObjectRelease(terminatedIter); terminatedIter = 0 }
        if let port { IONotificationPortDestroy(port) }
        port = nil
        serials = [:]
    }

    /// Every USB device with Apple's vendor id (0x05AC). A fresh dictionary
    /// per call: registering a notification consumes it.
    private static func appleUSBDevices() -> CFDictionary {
        let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        match["idVendor"] = 0x05AC
        return match as CFDictionary
    }

    private func drain(_ iter: io_iterator_t, arrived: Bool, notify: Bool) {
        while case let entry = IOIteratorNext(iter), entry != 0 {
            defer { IOObjectRelease(entry) }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &id)
            let serial = arrived ? Self.serial(of: entry)
                                 : (serials.removeValue(forKey: id) ?? Self.serial(of: entry))
            guard let serial, !serial.isEmpty else { continue }
            if arrived { serials[id] = serial }
            guard notify else { continue }
            if arrived { onAttached?(serial) } else { onDetached?(serial) }
        }
    }

    private static func serial(of entry: io_registry_entry_t) -> String? {
        IORegistryEntryCreateCFProperty(entry, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}
