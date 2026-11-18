// SleepAssertion — holds or releases one PreventSystemSleep assertion. When
// to hold it is decided in iMirrorCore/PowerPolicy.swift.
//
// macOS honours PreventSystemSleep on AC power only. On battery, idle sleep
// and lid close still sleep the Mac; the phones then show mac_asleep.
//
// Main thread only.

import Foundation
import IOKit.pwr_mgt

final class SleepAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var held = false

    func set(_ hold: Bool) {
        guard hold != held else { return }
        if hold {
            let name = "iMirror: an agent is driving a phone, or a phone is recovering" as CFString
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id)
            held = r == kIOReturnSuccess
            if !held { NSLog("iMirror: sleep assertion refused (\(r))") }
        } else {
            IOPMAssertionRelease(id)
            held = false
        }
        NSLog("iMirror: keeping the Mac awake: \(held)")
    }
}
