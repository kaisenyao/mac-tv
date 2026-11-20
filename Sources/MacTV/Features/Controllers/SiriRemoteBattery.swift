import Foundation
import IOKit
import IOKit.hid

/// The Siri Remote's charge, as the Bluetooth menu shows it: a `BatteryPercent` in the I/O Registry, on the
/// remote's HID services or the Bluetooth device above them. Read when a page showing it opens and when the
/// remote connects or disconnects, never on a timer; nil where this macOS doesn't expose it.
enum SiriRemoteBattery {
    static let vendorID = 0x004C
    static let productID = 0x0316
    static let key = "BatteryPercent"

    static func read() -> Int? {
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDVendorIDKey] = vendorID
        matching[kIOHIDProductIDKey] = productID
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var found: [Any?] = []
        var device = IOIteratorNext(iterator)
        while device != 0 {
            // Below the device (its HID event services), then above it (the Bluetooth device).
            for direction in [IOOptionBits(kIORegistryIterateRecursively),
                              IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)] {
                found.append(IORegistryEntrySearchCFProperty(device, kIOServicePlane, key as CFString, kCFAllocatorDefault, direction))
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }
        return percent(in: found)
    }

    /// The first value that is a charge: a number from 0 to 100.
    static func percent(in values: [Any?]) -> Int? {
        for case let number as NSNumber in values.compactMap({ $0 }) where CFGetTypeID(number) != CFBooleanGetTypeID() {
            let percent = number.intValue
            if (0...100).contains(percent), number.doubleValue == Double(percent) { return percent }
        }
        return nil
    }
}
