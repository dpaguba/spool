import Foundation

public enum ChainRunner {
    /// Set to `1` in the chained command's environment. A previous status line can itself run
    /// Spool's helper (a compound command, or a script that calls it); that inner helper must
    /// do nothing, or every status line would record twice and start helpers without end.
    public static let chainedVariable = "SPOOL_STATUSLINE_CHAINED"

    /// How long the chained command may run. Claude Code waits for Spool's helper and the
    /// helper waits for this command, so one that hangs, or a background process that keeps its
    /// output open, would block each helper for good while Claude Code starts new ones. Five
    /// seconds still lets slow user scripts finish, such as `git status` in a large repository.
    public static let timeout: Duration = .seconds(5)

    /// The most output read from the chained command: far more than a status line, and it
    /// bounds the helper's memory and what it passes on to Claude Code.
    public static let outputLimit = 65_536

    /// Runs `command` through `/bin/sh -c`, feeding `input` on stdin, and returns its stdout:
    /// all of it once the command exits, or what arrived before `timeout`, at most
    /// `outputLimit` bytes (on either limit the command is terminated). Empty `Data` if the
    /// process cannot be launched. stderr is discarded. The limits are parameters for tests.
    public static func run(command: String, input: Data,
                           timeout: Duration = timeout, outputLimit: Int = outputLimit) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment[chainedVariable] = "1"
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let exited = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Wakes the wait below when the command exits: a background process it started can keep
        // its stdout open long after, so the end of the output does not say it is done. The
        // handler holds the pipe, so its descriptor stays valid however late the exit comes.
        process.terminationHandler = { _ in
            var byte: UInt8 = 1
            _ = Darwin.write(exited.fileHandleForWriting.fileDescriptor, &byte, 1)
        }
        do {
            try process.run()
        } catch {
            return Data()
        }
        let output = exchange(input, stdin: stdin.fileHandleForWriting, stdout: stdout.fileHandleForReading,
                              exited: exited.fileHandleForReading, timeout: timeout, outputLimit: outputLimit)
        if process.isRunning { process.terminate() }
        return output
    }

    /// Writes `input` and reads the output at the same time, so neither side waits on a full
    /// pipe, until the command has exited, `timeout` has passed or `outputLimit` bytes have
    /// arrived. Grandchildren are not waited for: once the command has exited, what it wrote is
    /// already in the pipe.
    private static func exchange(_ input: Data, stdin: FileHandle, stdout: FileHandle, exited: FileHandle,
                                 timeout: Duration, outputLimit: Int) -> Data {
        let inFD = stdin.fileDescriptor
        let outFD = stdout.fileDescriptor
        let exitFD = exited.fileDescriptor
        // The command may exit without reading its input: a write then fails with EPIPE instead
        // of raising SIGPIPE, which would end the helper (or any process using this API).
        _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
        for fd in [inFD, outFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

        let deadline = ContinuousClock.now + timeout
        var output = Data()
        var written = 0
        var inputOpen = true
        var outputOpen = true
        func closeInput() {
            guard inputOpen else { return }
            inputOpen = false
            try? stdin.close()
        }
        defer { closeInput() }
        if input.isEmpty { closeInput() }

        while true {
            let left = deadline - ContinuousClock.now
            guard left > .zero else { return output }
            var fds = [pollfd(fd: exitFD, events: Int16(POLLIN), revents: 0)]
            if outputOpen { fds.append(pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)) }
            if inputOpen { fds.append(pollfd(fd: inFD, events: Int16(POLLOUT), revents: 0)) }
            let milliseconds = Int32(clamping: Int((left / .milliseconds(1)).rounded(.up)))
            if poll(&fds, nfds_t(fds.count), max(1, milliseconds)) < 0 {
                if errno == EINTR { continue }
                return output
            }
            for entry in fds where entry.revents != 0 {
                switch entry.fd {
                case inFD:
                    let n = input.withUnsafeBytes { buffer in
                        Darwin.write(inFD, buffer.baseAddress! + written, buffer.count - written)
                    }
                    if n > 0 {
                        written += n
                        if written == input.count { closeInput() }
                    } else if n < 0, errno != EAGAIN, errno != EINTR {
                        // EPIPE: the command stopped reading its input.
                        closeInput()
                    }
                case outFD:
                    switch drain(outFD, into: &output, limit: outputLimit) {
                    case .ended: outputOpen = false
                    case .full: return output
                    case .waiting: break
                    }
                default:
                    if outputOpen { _ = drain(outFD, into: &output, limit: outputLimit) }
                    return output
                }
            }
        }
    }

    private enum Drained { case waiting, ended, full }

    /// Reads what `fd` has now, up to `limit` bytes in `output` in all. A writer that never
    /// pauses would otherwise keep this loop going, even after the command has exited.
    private static func drain(_ fd: Int32, into output: inout Data, limit: Int) -> Drained {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let room = min(buffer.count, limit - output.count)
            guard room > 0 else { return .full }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, room) }
            if n > 0 {
                output.append(contentsOf: buffer[..<n])
            } else if n == 0 {
                return .ended
            } else if errno != EINTR {
                return errno == EAGAIN ? .waiting : .ended
            }
        }
    }
}

public enum StatuslineIngest {
    /// Records the rate limits found in `stdin` and returns the bytes to print:
    /// the previous statusline command's stdout, or empty. Never throws.
    ///
    /// Run by a command Spool chained to (`ChainRunner.chainedVariable` in `environment`), it
    /// records nothing, runs nothing and returns empty: the helper that chained it does both.
    public static func run(stdin: Data, paths: SpoolPaths, now: Date,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> Data {
        guard environment[ChainRunner.chainedVariable] == nil else { return Data() }
        if let windows = try? StatuslinePayload.windows(from: stdin, observedAt: now), !windows.isEmpty {
            _ = try? SampleStore(paths: paths).append(windows, at: now)
        }
        guard let data = try? Data(contentsOf: paths.chainState),
              let chain = try? JSONDecoder().decode(ChainState.self, from: data),
              let command = chain.previousCommand, !command.isEmpty
        else { return Data() }
        return ChainRunner.run(command: command, input: stdin)
    }
}
