import Foundation
import IOKit.hid

/// Talks to the UPS through macOS's own HID driver (IOHIDDevice), the way
/// NUT's nutdrv_qx "cypress" subdriver does over libusb: the query is sent as
/// 8-byte output reports (report ID 0), and the reply comes back as 8-byte
/// input reports until a carriage return.
///
/// It opens the device without seizing it, and it never resets it: on an
/// error it waits and asks again. A reset is what leaves some of these USB
/// bridges stuck off the bus until their port loses power.
final class HIDLink {
    let vendorID: Int
    let productID: Int
    var onReply: (String) -> Void = { _ in }
    var onAttach: () -> Void = {}
    var onDetach: () -> Void = {}
    var onError: (String) -> Void = { _ in }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var reply = [UInt8]()
    private var sentAt: Date?

    init(vendorID: Int, productID: Int) {
        self.vendorID = vendorID
        self.productID = productID
    }

    var attached: Bool { device != nil }

    /// Starts watching for the device on the current run loop.
    func start() -> IOReturn {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID,
        ] as CFDictionary)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue().detach(dev)
        }, me)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        return IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Sends the query, unless one is still waiting for its reply and has
    /// not yet timed out. Returns false when it could not be sent.
    @discardableResult
    func query(_ command: String, timeout: TimeInterval) -> Bool {
        guard let dev = device else { return false }
        if let s = sentAt {
            if Date().timeIntervalSince(s) < timeout { return true }
            onError("no reply in \(timeout)s (\(reply.count) bytes)")
        }
        let bytes = Array((command + "\r").utf8)
        sentAt = Date(); reply = []
        var i = 0
        while i < bytes.count {
            var chunk = [UInt8](repeating: 0, count: 8)
            for j in 0..<min(8, bytes.count - i) { chunk[j] = bytes[i + j] }
            let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, chunk, 8)
            if r != kIOReturnSuccess {
                sentAt = nil
                onError("send failed: \(hex(r))")
                return false
            }
            i += 8
        }
        return true
    }

    private func attach(_ dev: IOHIDDevice) {
        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { onError("open failed: \(hex(r))"); return }
        device = dev
        reply = []; sentAt = nil
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inBuf, 64, { ctx, result, _, _, _, report, len in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue().input(result, report, len)
        }, me)
        onAttach()
    }

    private func detach(_ dev: IOHIDDevice) {
        guard device === dev else { return }
        device = nil; sentAt = nil
        onDetach()
    }

    private func input(_ result: IOReturn, _ report: UnsafeMutablePointer<UInt8>, _ len: CFIndex) {
        guard result == kIOReturnSuccess else { onError("read failed: \(hex(result))"); return }
        guard sentAt != nil else { return }  // the late end of a reply already given up on
        reply += UnsafeBufferPointer(start: report, count: len)
        if let cr = reply.firstIndex(of: 13) {
            let line = String(decoding: reply[..<cr].filter { $0 != 0 }, as: UTF8.self)
            sentAt = nil; reply = []
            onReply(line)
        }
    }
}

func hex(_ r: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: r)) }
