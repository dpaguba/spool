import Foundation
import SpoolCore

signal(SIGPIPE, SIG_IGN)
let input = FileHandle.standardInput.readDataToEndOfFile()
let output = StatuslineIngest.run(stdin: input, paths: .standard(), now: .now,
                                  environment: ProcessInfo.processInfo.environment)
if !output.isEmpty {
    try? FileHandle.standardOutput.write(contentsOf: output)
}
exit(0)
