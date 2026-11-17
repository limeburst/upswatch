import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

private let stamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()
private let logLock = NSLock()

func log(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    print("\(stamp.string(from: Date())) \(s)")
}

let options: Options
do {
    options = try Options(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write("upswatch: \(error)\n\n\(usage)\n".data(using: .utf8)!)
    exit(2)
}

if options.once {
    let link = HIDLink(vendorID: options.vendorID, productID: options.productID)
    link.onReply = { line in
        guard let s = Status(line) else {
            FileHandle.standardError.write("upswatch: unexpected reply: \(line)\n".data(using: .utf8)!)
            exit(1)
        }
        let data = try! JSONSerialization.data(withJSONObject: s.json, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }
    link.onAttach = { link.query(options.query, timeout: options.timeout) }
    _ = link.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + options.timeout + 2) {
        FileHandle.standardError.write("upswatch: no reply from the UPS\n".data(using: .utf8)!)
        exit(1)
    }
    CFRunLoopRun()
}

let watcher = Watcher(options)
watcher.start()
CFRunLoopRun()
