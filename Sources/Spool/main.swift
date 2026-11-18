import AppKit

let arguments = CommandLine.arguments

if let flag = arguments.firstIndex(of: "--snapshot") {
    guard arguments.indices.contains(flag + 1) else {
        FileHandle.standardError.write(Data("usage: Spool --snapshot <dir>\n".utf8))
        exit(2)
    }
    do {
        try Snapshot.run(to: URL(fileURLWithPath: arguments[flag + 1], isDirectory: true))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
