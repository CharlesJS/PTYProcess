import XCTest
import System
import XCTAsyncAssertions
import CSErrors
import CSErrors_Foundation
import CwlPreconditionTesting
@testable import PTYProcess
@testable import PTYProcess_Foundation

@available(macOS 13.0, *)
class PTYProcessTests: XCTestCase {
    private actor OutputBuf {
        private var output = Data()

        nonisolated func startReading<S: AsyncSequence>(_ seq: S) where S.Element == UInt8 {
            Task {
                for try await byte in seq {
                    await self.append(byte)
                }
            }
        }

        func append(_ byte: UInt8) { output.append(byte) }

        func consumeUpTo(_ maxCount: Int) async -> Data {
            if maxCount < output.count {
                defer { output.replaceSubrange(..<output.index(output.startIndex, offsetBy: maxCount), with: Data()) }
                return output.prefix(maxCount)
            } else {
                defer { self.output.removeAll() }
                return self.output
            }
        }
    }

    class var supportsFilePath: Bool { true }

    private func testProcess(
        path: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        closure: (PTYProcess) async throws -> Void
    ) async throws {
        try await closure(PTYProcess(executablePath: path, arguments: arguments, currentDirectory: currentDirectory))

        if Self.supportsFilePath {
            try await closure(
                PTYProcess(
                    executablePath: FilePath(path),
                    arguments: arguments,
                    currentDirectory: currentDirectory.map { FilePath($0) }
                )
            )
        }

        try await closure(
            PTYProcess(
                executableURL: URL(filePath: path),
                arguments: arguments,
                currentDirectory: currentDirectory.map { URL(filePath: $0) }
            )
        )
    }

    private func testScript(_ script: String, expectedStatus: PTYProcess.Status) async throws {
        try await self.testProcess(path: "/bin/sh", arguments: ["-c", script]) { process in
            try await process.run()
            try await process.waitUntilExit()

            await XCTAssertEqualAsync(await process.status, expectedStatus)
        }
    }

    private func assertIsRunning(_ process: PTYProcess) async {
        switch await process.status {
        case .running: break
        default:
            XCTFail("Process is not running: \(await process.status)")
            return
        }
    }

    private func assertIsSuspended(_ process: PTYProcess) async {
        switch await process.status {
        case .suspended: break
        default:
            XCTFail("Process is not suspended: \(await process.status)")
            return
        }
    }

    private func waitForState(timeout: Duration = .seconds(10), state: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let timeoutTime = clock.now.advanced(by: timeout)

        while await !state(), clock.now < timeoutTime {
            try await Task.sleep(for: .microseconds(100))
        }

        await XCTAssertTrueAsync(await state())
    }

    @discardableResult
    private func waitForRunning(process: PTYProcess, timeout: Duration = .seconds(10)) async throws -> Int32 {
        var pid: Int32? = nil

        try await self.waitForState(timeout: timeout) {
            switch await process.status {
            case .running(let _pid):
                pid = _pid
                return true
            default:
                return false
            }
        }

        guard let pid else {
            throw Errno.timeout
        }

        return pid
    }

    private func waitForShellPrompt<S: AsyncSequence>(_ s: inout S) async throws where S.Element == UInt8 {
        for try await byte in s {
            if byte == 0x24 { // '$'
                return
            }
        }
    }

    private static var env: [String : String] = {
        ProcessInfo.processInfo.environment.filter { !$0.key.starts(with: "DYLD_") }
    }()

    private func parseEnv<S: AsyncSequence>(_ lines: S) async throws -> [String : String] where S.Element: StringProtocol {
        try await lines.reduce(into: [:]) { dict, line in
            if let separatorRange = line.range(of: "=", options: .literal) {
                dict[String(line[..<separatorRange.lowerBound])] = String(line[separatorRange.upperBound...])
            }
        }
    }

    func testInvalidPreconditions() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])

        XCTAssertThrowsError(_ = try process.ptyOptions) {
            XCTAssertEqual($0 as? Errno, .badFileDescriptor)
        }

        XCTAssertThrowsError(try process.setPTYOptions([])) {
            XCTAssertEqual($0 as? Errno, .badFileDescriptor)
        }

        await XCTAssertThrowsErrorAsync(try await process.terminate()) {
            XCTAssertEqual($0 as? Errno, .noSuchProcess)
        }

        await XCTAssertThrowsErrorAsync(try await process.interrupt()) {
            XCTAssertEqual($0 as? Errno, .noSuchProcess)
        }

        await XCTAssertThrowsErrorAsync(try await process.suspend()) {
            XCTAssertEqual($0 as? Errno, .noSuchProcess)
        }

        await XCTAssertThrowsErrorAsync(try await process.resume()) {
            XCTAssertEqual($0 as? Errno, .noSuchProcess)
        }

        XCTAssertNotNil(catchBadInstruction { _ = process.ptyBytes })
        XCTAssertNotNil(catchBadInstruction { _ = process.stdoutBytes })
        XCTAssertNotNil(catchBadInstruction { _ = process.stderrBytes })

        try await process.run(stdoutRequest: .none, stderrRequest: .none)
        XCTAssertNotNil(process.ptyBytes)
        XCTAssertNotNil(catchBadInstruction { _ = process.stdoutBytes })
        XCTAssertNotNil(catchBadInstruction { _ = process.stderrBytes })

        XCTAssertNotNil(catchBadInstruction { _ = try? process.makeRunner() })
    }

    func testStateChanges() async throws {
        try await self.testProcess(path: "/bin/sh", arguments: ["-i"]) { process in
            await XCTAssertEqualAsync(await process.status, .notRunYet)
            XCTAssertEqual(process.executablePath, FilePath("/bin/sh"))
            XCTAssertEqual(process.rawExecutablePath, "/bin/sh")

            try await process.run(signalMask: 0)

            let pid = try await self.waitForRunning(process: process)
            await XCTAssertEqualAsync(await process.status, .running(pid))

            try await process.suspend()
            try await self.waitForState { await process.status == .suspended(pid) }
            await XCTAssertEqualAsync(await process.status, .suspended(pid))

            try await process.resume()
            try await self.waitForState { await process.status == .running(pid) }
            await XCTAssertEqualAsync(await process.status, .running(pid))

            try process.ptyHandle?.write(contentsOf: "exit\n".data(using: .utf8)!)
            try await self.waitForState { await process.status == .exited(0) }
            await XCTAssertEqualAsync(await process.status, .exited(0))
        }
    }

    func testStateEquality() {
        XCTAssertEqual(PTYProcess.Status.notRunYet, .notRunYet)
        XCTAssertNotEqual(PTYProcess.Status.notRunYet, .running(0))

        XCTAssertEqual(PTYProcess.Status.running(0), .running(0))
        XCTAssertNotEqual(PTYProcess.Status.running(0), .running(1))
        XCTAssertNotEqual(PTYProcess.Status.running(0), .suspended(0))

        XCTAssertEqual(PTYProcess.Status.suspended(0), .suspended(0))
        XCTAssertNotEqual(PTYProcess.Status.suspended(0), .suspended(1))
        XCTAssertNotEqual(PTYProcess.Status.suspended(0), .running(0))

        XCTAssertEqual(PTYProcess.Status.exited(0), .exited(0))
        XCTAssertNotEqual(PTYProcess.Status.exited(0), .exited(1))
        XCTAssertNotEqual(PTYProcess.Status.exited(0), .running(0))

        XCTAssertEqual(PTYProcess.Status.uncaughtSignal(1), .uncaughtSignal(1))
        XCTAssertNotEqual(PTYProcess.Status.uncaughtSignal(1), .uncaughtSignal(2))
        XCTAssertNotEqual(PTYProcess.Status.uncaughtSignal(1), .exited(1))
    }

    func testStatusMappings() {
        var sigInfo = siginfo_t()

        sigInfo.si_code = CLD_EXITED
        sigInfo.si_status = 123
        XCTAssertEqual(PTYProcess.Status(signalInfo: sigInfo), .exited(123))

        sigInfo.si_code = CLD_KILLED
        sigInfo.si_status = 234
        XCTAssertEqual(PTYProcess.Status(signalInfo: sigInfo), .uncaughtSignal(234))

        sigInfo.si_code = CLD_DUMPED
        sigInfo.si_status = 345
        XCTAssertEqual(PTYProcess.Status(signalInfo: sigInfo), .uncaughtSignal(345))

        sigInfo.si_code = CLD_STOPPED
        sigInfo.si_pid = 456
        XCTAssertEqual(PTYProcess.Status(signalInfo: sigInfo), .suspended(456))

        sigInfo.si_code = CLD_CONTINUED
        sigInfo.si_pid = 567
        XCTAssertEqual(PTYProcess.Status(signalInfo: sigInfo), .running(567))

        sigInfo.si_code = CLD_NOOP
        XCTAssertNil(PTYProcess.Status(signalInfo: sigInfo))
    }

    func testInvalidPath() async throws {
        let process = PTYProcess(executablePath: "/does/not/exist/\(UUID().uuidString)")

        await XCTAssertThrowsErrorAsync(try await process.run()) {
            guard let err = $0 as? CocoaError else {
                XCTFail("Expected CocoaError(.fileNoSuchFile), got \($0)")
                return
            }

            XCTAssertEqual(err.code, .fileReadNoSuchFile)
            XCTAssertEqual(err.underlyingError as? Errno, .noSuchFileOrDirectory)
        }
    }

    func testInvalidURLScheme() async throws {
        let url = URL(string: "https://www.something.com/foo/bar")!

        XCTAssertThrowsError(try PTYProcess(executableURL: url)) {
            XCTAssertEqual($0 as? CocoaError, CocoaError(.fileReadUnsupportedScheme, url: url))
        }
    }

    func testOptions() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])
        try await process.run()

        let fd = try XCTUnwrap(process.rawPTY)
        let localFlagMask = tcflag_t(ECHO | ICANON)
        let outputFlagMask = tcflag_t(ONLCR)
        let defaultLocalFlags = tcflag_t(ECHO | ICANON)
        let defaultOutputFlags = tcflag_t(0)

        func getFlags() throws -> (local: tcflag_t, output: tcflag_t) {
            var t = termios()

            try callPOSIXFunction(expect: .zero) { tcgetattr(fd, &t) }

            return (local: t.c_lflag & localFlagMask, t.c_oflag & outputFlagMask)
        }

        func setFlags(local: tcflag_t, output: tcflag_t) throws {
            var t = termios()

            try callPOSIXFunction(expect: .zero) { tcgetattr(fd, &t) }
            t.c_lflag = (t.c_lflag & ~localFlagMask) | local
            t.c_oflag = (t.c_oflag & ~outputFlagMask) | output
            try callPOSIXFunction(expect: .zero) { tcsetattr(fd, 0, &t) }
        }

        func checkMatch(options: PTYProcess.PTYOptions, localFlags: tcflag_t, outputFlags: tcflag_t) throws {
            try process.setPTYOptions([], immediately: true, drainFirst: true)
            let (local: initialLocal, output: initialOutput) = try getFlags()
            XCTAssertEqual(initialLocal, defaultLocalFlags)
            XCTAssertEqual(initialOutput, defaultOutputFlags)

            try process.setPTYOptions(options, immediately: true, drainFirst: true)
            let (local: newLocal, output: newOutput) = try getFlags()
            XCTAssertEqual(newLocal, localFlags)
            XCTAssertEqual(newOutput, outputFlags)

            try setFlags(local: defaultLocalFlags, output: defaultOutputFlags)
            XCTAssertEqual(try process.ptyOptions, [])

            try setFlags(local: localFlags, output: outputFlags)
            XCTAssertEqual(try process.ptyOptions, options)
        }

        try checkMatch(options: [], localFlags: defaultLocalFlags, outputFlags: defaultOutputFlags)
        try checkMatch(options: .disableEcho, localFlags: tcflag_t(ICANON), outputFlags: 0)
        try checkMatch(options: .nonCanonical, localFlags: tcflag_t(ECHO), outputFlags: 0)
        try checkMatch(options: .outputCRLF, localFlags: tcflag_t(ECHO | ICANON), outputFlags: tcflag_t(ONLCR))
        try checkMatch(options: [.disableEcho, .nonCanonical], localFlags: 0, outputFlags: 0)
        try checkMatch(options: [.disableEcho, .outputCRLF], localFlags: tcflag_t(ICANON), outputFlags: tcflag_t(ONLCR))
        try checkMatch(options: [.nonCanonical, .outputCRLF], localFlags: tcflag_t(ECHO), outputFlags: tcflag_t(ONLCR))
        try checkMatch(options: [.disableEcho, .nonCanonical, .outputCRLF], localFlags: 0, outputFlags: tcflag_t(ONLCR))

        try process.ptyHandle?.write(contentsOf: "exit\n".data(using: .ascii)!)
        try await process.waitUntilExit()
    }

    private func assertNoFileDescriptorsLeftOpen(closure: () async throws -> Void) async throws {
        func isDescriptorOpen(_ fd: Int32) throws -> Bool {
            do {
                try callPOSIXFunction(expect: .notSpecific(-1)) { fcntl(fd, F_GETFD) }
                return true
            } catch Errno.badFileDescriptor {
                return false
            } catch {
                throw error
            }
        }

        func getOpenFileDescriptors() throws -> [Int32] {
            try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap {
                guard let fd = Int32($0) else { throw CocoaError(.fileReadUnknown) }

                return try isDescriptorOpen(fd) ? fd : nil
            }
        }

        let initialFDs = try getOpenFileDescriptors()

        try await closure()

        XCTAssertEqual(try getOpenFileDescriptors(), initialFDs)
    }


    func testDoesNotLeaveFileDescriptorsOpenWithPTYOnSuccess() async throws {
        try await self.assertNoFileDescriptorsLeftOpen {
            let ptyProcess = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])
            try await ptyProcess.run(stdoutRequest: .pty, stderrRequest: .pty)

            try ptyProcess.ptyHandle?.write(contentsOf: "exit\n".data(using: .utf8)!)

            XCTAssertGreaterThan(try XCTUnwrap(ptyProcess.ptyHandle?.readToEnd()).count, 0)

            try await ptyProcess.waitUntilExit()
        }
    }

    func testDoesNotLeaveFileDescriptorsOpenWithPipesOnSuccess() async throws {
        try await self.assertNoFileDescriptorsLeftOpen {
            let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])
            try await process.run(stdoutRequest: .pipe, stderrRequest: .pipe)

            try process.ptyHandle?.write(contentsOf: "echo 'foo'\n".data(using: .utf8)!)
            try process.ptyHandle?.write(contentsOf: "exit\n".data(using: .utf8)!)

            XCTAssertEqual(try process.stdoutHandle?.readToEnd(), "foo\n".data(using: .ascii)!)
            XCTAssertGreaterThan(try XCTUnwrap(process.stderrHandle?.readToEnd()).count, 0)

            try await process.waitUntilExit()
        }
    }

    func testDoesNotLeaveFileDescriptorsOpenWithPTYOnFailure() async throws {
        try await self.assertNoFileDescriptorsLeftOpen {
            await XCTAssertThrowsErrorAsync(try await {
                let ptyProcess = PTYProcess(executablePath: "/does/not/exist/\(UUID().uuidString)")
                try await ptyProcess.run(stdoutRequest: .pty, stderrRequest: .pty)
            }()) {
                XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadNoSuchFile)
                XCTAssertEqual($0.underlyingError as? Errno, .noSuchFileOrDirectory)
            }
        }
    }

    func testDoesNotLeaveFileDescriptorsOpenWithPipesOnFailure() async throws {
        try await self.assertNoFileDescriptorsLeftOpen {
            await XCTAssertThrowsErrorAsync(try await {
                let ptyProcess = PTYProcess(executablePath: "/does/not/exist/\(UUID().uuidString)")
                try await ptyProcess.run(stdoutRequest: .pipe, stderrRequest: .pipe)
            }()) {
                XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadNoSuchFile)
                XCTAssertEqual($0.underlyingError as? Errno, .noSuchFileOrDirectory)
            }
        }
    }

    func testExit0() async throws {
        try await self.testScript("exit 0", expectedStatus: .exited(0))
    }

    func testExit1() async throws {
        try await self.testScript("exit 1", expectedStatus: .exited(1))
    }

    func testExit100() async throws {
        try await self.testScript("exit 100", expectedStatus: .exited(100))
    }

    func testSleep2() async throws {
        try await self.testScript("sleep 2", expectedStatus: .exited(0))
    }

    func testUncaughtSignal() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-c", "/bin/kill -TERM $$"])

        try await process.run(signalMask: 0)

        await XCTAssertEqualAsync(try await process.waitUntilExit(), .uncaughtSignal(SIGTERM))
        await XCTAssertEqualAsync(await process.status, .uncaughtSignal(SIGTERM))
    }

    func testPipeStdout() async throws {
        let process = PTYProcess(executablePath: "/bin/echo", arguments: ["Hello World"])

        try await process.run(stdoutRequest: .pipe)
        var linesIterator = process.stdoutBytes.lines.makeAsyncIterator()

        XCTAssertNotEqual(process.stdout, process.pty)

        await XCTAssertEqualAsync(try await linesIterator.next(), "Hello World")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await linesIterator.next(), nil)
    }

    func testPipeStdoutWithShell() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])

        try await process.run(stdoutRequest: .pipe)
        var linesIterator = process.stdoutBytes.lines.makeAsyncIterator()

        XCTAssertNotEqual(process.stdout, process.pty)

        try process.pty?.writeAll("echo 'Hello, World.'\n".data(using: .utf8)!)
        try await XCTAssertEqualAsync(await linesIterator.next(), "Hello, World.")

        try process.pty?.writeAll("exit\n".data(using: .utf8)!)
        try await XCTAssertEqualAsync(await linesIterator.next(), nil)

        try await process.waitUntilExit()
    }

    func testPtyStdoutWithEcho() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])

        try await process.run(stdoutRequest: .pty)
        var ptyBytes = process.ptyBytes
        var linesIterator = ptyBytes.lines.makeAsyncIterator()

        XCTAssertEqual(process.stdout, process.pty)
        XCTAssertEqual(process.rawStdout, process.pty?.rawValue)

        try await self.waitForShellPrompt(&ptyBytes)
        try process.pty?.writeAll("echo 'Hello, World.'\n".data(using: .utf8)!)
        try await XCTAssertEqualAsync(await linesIterator.next(), "echo 'Hello, World.'")
        try await XCTAssertEqualAsync(await linesIterator.next(), "Hello, World.")

        try await self.waitForShellPrompt(&ptyBytes)
        try process.pty?.writeAll("exit\n".data(using: .utf8)!)
        try await XCTAssertEqualAsync(await linesIterator.next(), "exit")
        try await XCTAssertEqualAsync(await linesIterator.next(), "exit")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await linesIterator.next(), nil)
    }

    func testPtyStdoutNoEcho() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])

        try await process.run(stdoutRequest: .pty, options: [.disableEcho])
        var stdoutBytes = process.stdoutBytes
        var linesIterator = stdoutBytes.lines.makeAsyncIterator()

        XCTAssertEqual(process.stdout, process.pty)

        try await self.waitForShellPrompt(&stdoutBytes)
        try process.pty?.writeAll("echo 'Hello, World.'\n".data(using: .utf8)!)
        try await XCTAssertEqualAsync(await linesIterator.next(), "Hello, World.")

        try await self.waitForShellPrompt(&stdoutBytes)
        try process.pty?.writeAll("exit\n".data(using: .utf8)!)
        try await XCTAssertEqualAsync(await linesIterator.next(), "exit")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await linesIterator.next(), nil)
    }

    func testPtyOutputCanonicalMode() async throws {
        let process = PTYProcess(executablePath: "/bin/cat")

        try await process.run(stdoutRequest: .pty, options: [.disableEcho], signalMask: 0)

        let outputBuf = OutputBuf()
        outputBuf.startReading(process.stdoutBytes)

        XCTAssertEqual(process.stdout, process.pty)

        try process.pty?.writeAll("foo\nbar\nbaz".data(using: .utf8)!)
        try await Task.sleep(for: .milliseconds(5))
        await XCTAssertEqualAsync(String(data: await outputBuf.consumeUpTo(100), encoding: .ascii), "foo\nbar\n")

        try process.pty?.writeAll("\n".data(using: .utf8)!)
        try await Task.sleep(for: .milliseconds(5))
        await XCTAssertEqualAsync(String(data: await outputBuf.consumeUpTo(100), encoding: .ascii), "baz\n")

        try await process.terminate()
        try await process.waitUntilExit()

        await XCTAssertEqualAsync(await outputBuf.consumeUpTo(100), Data())
    }

    func testPtyStdoutNonCanonicalMode() async throws {
        let process = PTYProcess(executablePath: "/bin/cat")

        try await process.run(stdoutRequest: .pty, options: [.disableEcho, .nonCanonical], signalMask: 0)

        let outputBuf = OutputBuf()
        outputBuf.startReading(process.stdoutBytes)

        XCTAssertEqual(process.stdout, process.pty)

        try process.pty?.writeAll("foo\nbar\nbaz".data(using: .utf8)!)
        try await Task.sleep(for: .milliseconds(5))
        await XCTAssertEqualAsync(String(data: await outputBuf.consumeUpTo(100), encoding: .ascii), "foo\nbar\nbaz")

        try process.pty?.writeAll("\n".data(using: .utf8)!)
        try await Task.sleep(for: .milliseconds(5))
        await XCTAssertEqualAsync(String(data: await outputBuf.consumeUpTo(100), encoding: .ascii), "\n")

        try await process.terminate()
        try await process.waitUntilExit()

        await XCTAssertEqualAsync(await outputBuf.consumeUpTo(100), Data())
    }

    func testPipeStderr() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-c", "echo 'the dog ate my homework' >&2"])

        try await process.run(stderrRequest: .pipe)
        var linesIterator = process.stderrBytes.lines.makeAsyncIterator()

        XCTAssertNotEqual(process.stderr, process.pty)

        await XCTAssertEqualAsync(try await linesIterator.next(), "the dog ate my homework")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await linesIterator.next(), nil)
    }

    func testPtyStderr() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-c", "echo 'uh oh spaghettios' >&2"])

        try await process.run(stderrRequest: .pty)
        var linesIterator = process.stderrBytes.lines.makeAsyncIterator()

        XCTAssertEqual(process.stderr, process.pty)

        try await XCTAssertEqualAsync(await linesIterator.next(), "uh oh spaghettios")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await linesIterator.next(), nil)
    }

    func testPipeStdoutAndStderr() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: [
            "-c", "echo 'must be some way outta here'; echo \"there's too much confusion; i can't get no relief\" >&2"
        ])

        try await process.run(stdoutRequest: .pipe, stderrRequest: .pipe)
        var stdoutLines = process.stdoutBytes.lines.makeAsyncIterator()
        var stderrLines = process.stderrBytes.lines.makeAsyncIterator()

        XCTAssertNotEqual(process.stdout, process.pty)
        XCTAssertNotEqual(process.stderr, process.pty)

        try await XCTAssertEqualAsync(await stdoutLines.next(), "must be some way outta here")
        try await XCTAssertEqualAsync(await stderrLines.next(), "there's too much confusion; i can't get no relief")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await stdoutLines.next(), nil)
        try await XCTAssertEqualAsync(await stderrLines.next(), nil)
    }

    func testPipeStdoutAndPtyStderr() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: [
            "-c", "echo 'there is light at the end of the tunnel'; echo \"it's where the roof caved in\" >&2"
        ])

        try await process.run(stdoutRequest: .pipe, stderrRequest: .pty)
        var stdoutLines = process.stdoutBytes.lines.makeAsyncIterator()
        var stderrLines = process.stderrBytes.lines.makeAsyncIterator()

        XCTAssertNotEqual(process.stdout, process.pty)
        XCTAssertEqual(process.stderr, process.pty)

        try await XCTAssertEqualAsync(await stdoutLines.next(), "there is light at the end of the tunnel")
        try await XCTAssertEqualAsync(await stderrLines.next(), "it's where the roof caved in")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await stdoutLines.next(), nil)
        try await XCTAssertEqualAsync(await stderrLines.next(), nil)
    }

    func testPtyStdoutAndPipeStderr() async throws {
        let args = ["-c", "echo 'must be some way outta here'; echo \"too much confusion; i can't get no relief\" >&2"]
        let process = PTYProcess(executablePath: "/bin/sh", arguments: args)

        try await process.run(stdoutRequest: .pty, stderrRequest: .pipe)
        var stdoutLines = process.stdoutBytes.lines.makeAsyncIterator()
        var stderrLines = process.stderrBytes.lines.makeAsyncIterator()

        XCTAssertEqual(process.stdout, process.pty)
        XCTAssertNotEqual(process.stderr, process.pty)

        try await XCTAssertEqualAsync(await stdoutLines.next(), "must be some way outta here")
        try await XCTAssertEqualAsync(await stderrLines.next(), "too much confusion; i can't get no relief")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await stdoutLines.next(), nil)
        try await XCTAssertEqualAsync(await stderrLines.next(), nil)
    }

    func testPtyStdoutAndStderr() async throws {
        let args = ["-c", "echo 'must be some way outta here'; echo \"too much confusion; i can't get no relief\" >&2"]
        let process = PTYProcess(executablePath: "/bin/sh", arguments: args)

        try await process.run(stdoutRequest: .pty, stderrRequest: .pty)
        var linesIterator = process.stdoutBytes.lines.makeAsyncIterator()

        XCTAssertEqual(process.stdout, process.pty)
        XCTAssertEqual(process.stderr, process.pty)

        try await XCTAssertEqualAsync(await linesIterator.next(), "must be some way outta here")
        try await XCTAssertEqualAsync(await linesIterator.next(), "too much confusion; i can't get no relief")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await linesIterator.next(), nil)
    }

    func testPassthroughEnvironment() async throws {
        let process = PTYProcess(executablePath: "/usr/bin/env")

        try await process.run(stdoutRequest: .pipe)
        let env = try await self.parseEnv(process.stdoutBytes.lines)

        try await process.waitUntilExit()

        XCTAssertEqual(env, Self.env)
    }

    func testEmptyEnvironment() async throws {
        let process = PTYProcess(executablePath: "/usr/bin/env", environment: [:])

        try await process.run(stdoutRequest: .pipe)
        let env = try await self.parseEnv(process.stdoutBytes.lines)

        try await process.waitUntilExit()

        XCTAssertEqual(env, [:])
    }

    func testCustomEnvironment() async throws {
        let customEnv = ["VORLON": "Who are you", "SHADOW": "What do you want"]
        let process = PTYProcess(executablePath: "/usr/bin/env", environment: customEnv)

        try await process.run(stdoutRequest: .pipe)
        let env = try await self.parseEnv(process.stdoutBytes.lines)

        try await process.waitUntilExit()

        XCTAssertEqual(env, customEnv)
    }

    func testCurrentDirectory() async throws {
        try await self.testProcess(path: "/bin/pwd") { process in
            let currentDir = URL.currentDirectory()
            try await process.run(stdoutRequest: .pipe)
            var linesIterator = process.stdoutBytes.lines.makeAsyncIterator()

            let path = try await linesIterator.next()

            try await XCTAssertEqualAsync(URL(filePath: XCTUnwrap(path)).standardizedFileURL, currentDir.standardizedFileURL)

            try await process.waitUntilExit()
        }
    }

    func testCustomCurrentDirectory() async throws {
        try await self.testProcess(path: "/bin/pwd", currentDirectory: "/Users/Shared") { process in
            XCTAssertEqual(process.currentDirectory, FilePath("/Users/Shared"))
            XCTAssertEqual(process.rawCurrentDirectory, "/Users/Shared")

            try await process.run(stdoutRequest: .pipe)
            var linesIterator = process.stdoutBytes.lines.makeAsyncIterator()

            await XCTAssertEqualAsync(try await linesIterator.next(), "/Users/Shared")

            try await process.waitUntilExit()
        }
    }

    func testEmptyCurrentDirectoryBehavesAsNil() async throws {
        try await self.testProcess(path: "/bin/pwd", currentDirectory: "") { process in
            try await process.run(stdoutRequest: .pipe)
            var linesIterator = process.stdoutBytes.lines.makeAsyncIterator()

            let path = try await linesIterator.next()

            try await XCTAssertEqualAsync(
                URL(fileURLWithPath: XCTUnwrap(path)).standardizedFileURL,
                URL.currentDirectory().standardizedFileURL
            )

            try await process.waitUntilExit()
        }
    }

    func testInterrupt() async throws {
        let process = PTYProcess(executablePath: "/bin/sleep", arguments: ["100"])

        try await process.run(signalMask: 0)

        try await Task.sleep(for: .milliseconds(5))

        await self.assertIsRunning(process)

        try await process.interrupt()

        await XCTAssertEqualAsync(try await process.waitUntilExit(), .uncaughtSignal(SIGINT))
        await XCTAssertEqualAsync(await process.status, .uncaughtSignal(SIGINT))
    }

    func testTerminate() async throws {
        let process = PTYProcess(executablePath: "/bin/sleep", arguments: ["100"])

        try await process.run(signalMask: 0)

        try await Task.sleep(for: .milliseconds(5))

        await self.assertIsRunning(process)

        try await process.terminate()

        await XCTAssertEqualAsync(try await process.waitUntilExit(), .uncaughtSignal(SIGTERM))
        await XCTAssertEqualAsync(await process.status, .uncaughtSignal(SIGTERM))
    }

    func testSuspendAndResume() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])

        try await process.run(signalMask: 0)
        let pid = try await self.waitForRunning(process: process)
        await self.assertIsRunning(process)

        try await process.suspend()
        try await self.waitForState { await process.status == .suspended(pid) }
        await self.assertIsSuspended(process)

        try await process.resume()
        try await self.waitForState { await process.status == .running(pid) }
        await self.assertIsRunning(process)

        try await process.suspend()
        try await self.waitForState { await process.status == .suspended(pid) }
        await self.assertIsSuspended(process)

        try process.ptyHandle?.write(contentsOf: "exit\n".data(using: .ascii)!)
        try await Task.sleep(for: .seconds(1))
        await self.assertIsSuspended(process)

        try await process.resume()
        try await process.waitUntilExit()

        await XCTAssertEqualAsync(await process.status, .exited(0))
    }

    func testRequestNullStdout() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-c", "/usr/bin/env; /usr/bin/env >&2"])

        try await process.run(stdoutRequest: .null, stderrRequest: .pipe)

        var stdoutData = Data()
        var stderrData = Data()

        for try await eachByte in process.stdoutBytes {
            stdoutData.append(eachByte)
        }

        for try await eachByte in process.stderrBytes {
            stderrData.append(eachByte)
        }

        try await process.waitUntilExit()

        XCTAssertEqual(stdoutData, Data())
        XCTAssertNotEqual(stderrData, Data())
    }

    func testRequestNullStderr() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-c", "/usr/bin/env; /usr/bin/env >&2"])

        try await process.run(stdoutRequest: .pipe, stderrRequest: .null)

        var stdoutData = Data()
        var stderrData = Data()

        for try await eachByte in process.stdoutBytes {
            stdoutData.append(eachByte)
        }

        for try await eachByte in process.stderrBytes {
            stderrData.append(eachByte)
        }

        try await process.waitUntilExit()

        XCTAssertEqual(stderrData, Data())
        XCTAssertNotEqual(stdoutData, Data())
    }

    func testRequestNullStdoutAndStderr() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-c", "/usr/bin/env; /usr/bin/env >&2"])

        try await process.run(stdoutRequest: .null, stderrRequest: .null)

        var stdoutData = Data()
        var stderrData = Data()

        for try await eachByte in process.stdoutBytes {
            stdoutData.append(eachByte)
        }

        for try await eachByte in process.stderrBytes {
            stderrData.append(eachByte)
        }

        try await process.waitUntilExit()

        XCTAssertEqual(stderrData, Data())
        XCTAssertEqual(stdoutData, Data())
    }

    func testFileDescriptorsAreNotInherited() async throws {
        let process1 = PTYProcess(executablePath: "/bin/dash", arguments: ["-c", "/usr/sbin/lsof -p $$"])

        try await process1.run(stdoutRequest: .pipe, stderrRequest: .null)

        let originalLineCount = try await process1.stdoutBytes.lines.reduce(0) { count, _ in count + 1 }

        let extraFDs = try (0..<8).map { _ in try FileDescriptor.standardOutput.duplicate() }
        defer { extraFDs.forEach { _ = try? $0.close() } }

        let process2 = PTYProcess(executablePath: "/bin/dash", arguments: ["-c", "/usr/sbin/lsof -p $$"])

        try await process2.run(stdoutRequest: .pipe, stderrRequest: .null)

        let newLineCount = try await process2.stdoutBytes.lines.reduce(0) { count, _ in count + 1 }

        XCTAssertEqual(originalLineCount, newLineCount)
    }

    func testProcessGroup() async throws {
        // The process group of the child process should be different to the parent's.
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-c", "/bin/ps -p $$ -o pgid="])

        try await process.run(stdoutRequest: .pipe, stderrRequest: .null)
        try await process.waitUntilExit()

        await XCTAssertEqualAsync(await process.status, .exited(0))

        guard let data = try process.stdoutHandle?.readToEnd(),
              let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let childPGID = pid_t(string) else {
            XCTFail("Couldn't get child pgid")
            return
        }

        XCTAssertNotEqual(childPGID, getpgrp())
    }

    func testIncorrectSignalsSentToWatcher() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])

        try await process.run()

        // cause watcher to consume a `wait` on the pid
        kill(ProcessInfo.processInfo.processIdentifier, SIGCHLD)

        try process.ptyHandle?.write(contentsOf: "exit\n".data(using: .utf8)!)

        await XCTAssertThrowsErrorAsync(try await process.waitUntilExit()) {
            XCTAssertEqual($0 as? Errno, .noChildProcess)
        }
    }
}
