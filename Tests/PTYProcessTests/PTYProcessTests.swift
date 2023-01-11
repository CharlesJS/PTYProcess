import XCTest
import System
import XCTAsyncAssertions
import CSErrors
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

    private func testProcess(
        path: String,
        arguments: [String] = [],
        closure: (PTYProcess) async throws -> Void
    ) async throws {
        try await closure(PTYProcess(executablePath: path, arguments: arguments))
        try await closure(PTYProcess(executablePath: FilePath(path), arguments: arguments))
        try await closure(PTYProcess(executableURL: URL(fileURLWithPath: path), arguments: arguments))
    }

    private func testScript(_ script: String, expectedStatus: PTYProcess.Status) async throws {
        try await self.testProcess(path: "/bin/sh", arguments: ["-c", script]) { process in
            try process.run()
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

        try process.run(signalMask: 0)

        await XCTAssertEqualAsync(try await process.waitUntilExit(), .uncaughtSignal(SIGTERM))
        await XCTAssertEqualAsync(await process.status, .uncaughtSignal(SIGTERM))
    }

    func testPipeStdout() async throws {
        let process = PTYProcess(executablePath: "/bin/echo", arguments: ["Hello World"])

        try process.run(stdoutRequest: .pipe)
        var linesIterator = process.stdoutBytes.lines.makeAsyncIterator()

        XCTAssertNotEqual(process.stdout, process.pty)

        await XCTAssertEqualAsync(try await linesIterator.next(), "Hello World")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await linesIterator.next(), nil)
    }

    func testPipeStdoutWithShell() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])

        try process.run(stdoutRequest: .pipe)
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

        try process.run(stdoutRequest: .pty)
        var stdoutBytes = process.stdoutBytes
        var linesIterator = stdoutBytes.lines.makeAsyncIterator()

        XCTAssertEqual(process.stdout, process.pty)

        try await self.waitForShellPrompt(&stdoutBytes)
        try process.pty?.writeAll("echo 'Hello, World.'\n".data(using: .utf8)!)
        try await XCTAssertEqualAsync(await linesIterator.next(), "echo 'Hello, World.'")
        try await XCTAssertEqualAsync(await linesIterator.next(), "Hello, World.")

        try await self.waitForShellPrompt(&stdoutBytes)
        try process.pty?.writeAll("exit\n".data(using: .utf8)!)
        try await XCTAssertEqualAsync(await linesIterator.next(), "exit")
        try await XCTAssertEqualAsync(await linesIterator.next(), "exit")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await linesIterator.next(), nil)
    }

    func testPtyStdoutNoEcho() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])

        try process.run(stdoutRequest: .pty, options: [.disableEcho])
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

        try process.run(stdoutRequest: .pty, options: [.disableEcho], signalMask: 0)

        let outputBuf = OutputBuf()
        outputBuf.startReading(process.stdoutBytes)

        XCTAssertEqual(process.stdout, process.pty)

        try process.pty?.writeAll("foo\nbar\nbaz".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 5)
        await XCTAssertEqualAsync(String(data: await outputBuf.consumeUpTo(100), encoding: .ascii), "foo\nbar\n")

        try process.pty?.writeAll("\n".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 5)
        await XCTAssertEqualAsync(String(data: await outputBuf.consumeUpTo(100), encoding: .ascii), "baz\n")

        try await process.terminate()
        try await process.waitUntilExit()

        await XCTAssertEqualAsync(await outputBuf.consumeUpTo(100), Data())
    }

    func testPtyStdoutNonCanonicalMode() async throws {
        let process = PTYProcess(executablePath: "/bin/cat")

        try process.run(stdoutRequest: .pty, options: [.disableEcho, .nonCanonical], signalMask: 0)

        let outputBuf = OutputBuf()
        outputBuf.startReading(process.stdoutBytes)

        XCTAssertEqual(process.stdout, process.pty)

        try process.pty?.writeAll("foo\nbar\nbaz".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 5)
        await XCTAssertEqualAsync(String(data: await outputBuf.consumeUpTo(100), encoding: .ascii), "foo\nbar\nbaz")

        try process.pty?.writeAll("\n".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 5)
        await XCTAssertEqualAsync(String(data: await outputBuf.consumeUpTo(100), encoding: .ascii), "\n")

        try await process.terminate()
        try await process.waitUntilExit()

        await XCTAssertEqualAsync(await outputBuf.consumeUpTo(100), Data())
    }

    func testPipeStderr() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-c", "echo 'the dog ate my homework' >&2"])

        try process.run(stderrRequest: .pipe)
        var linesIterator = process.stderrBytes.lines.makeAsyncIterator()

        XCTAssertNotEqual(process.stderr, process.pty)

        await XCTAssertEqualAsync(try await linesIterator.next(), "the dog ate my homework")

        try await process.waitUntilExit()

        try await XCTAssertEqualAsync(await linesIterator.next(), nil)
    }

    func testPtyStderr() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-c", "echo 'uh oh spaghettios' >&2"])

        try process.run(stderrRequest: .pty)
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

        try process.run(stdoutRequest: .pipe, stderrRequest: .pipe)
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

        try process.run(stdoutRequest: .pipe, stderrRequest: .pty)
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

        try process.run(stdoutRequest: .pty, stderrRequest: .pipe)
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

        try process.run(stdoutRequest: .pty, stderrRequest: .pty)
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

        try process.run(stdoutRequest: .pipe)
        let env = try await self.parseEnv(process.stdoutBytes.lines)

        try await process.waitUntilExit()

        XCTAssertEqual(env, Self.env)
    }

    func testEmptyEnvironment() async throws {
        let process = PTYProcess(executablePath: "/usr/bin/env", environment: [:])

        try process.run(stdoutRequest: .pipe)
        let env = try await self.parseEnv(process.stdoutBytes.lines)

        try await process.waitUntilExit()

        XCTAssertEqual(env, [:])
    }

    func testCustomEnvironment() async throws {
        let customEnv = ["VORLON": "Who are you", "SHADOW": "What do you want"]
        let process = PTYProcess(executablePath: "/usr/bin/env", environment: customEnv)

        try process.run(stdoutRequest: .pipe)
        let env = try await self.parseEnv(process.stdoutBytes.lines)

        try await process.waitUntilExit()

        XCTAssertEqual(env, customEnv)
    }

    func testCurrentDirectory() async throws {
        let process = PTYProcess(executablePath: "/bin/pwd")

        try process.run(stdoutRequest: .pipe)
        var linesIterator = process.stdoutBytes.lines.makeAsyncIterator()

        let path = try await linesIterator.next()

        try await XCTAssertEqualAsync(
            URL(fileURLWithPath: XCTUnwrap(path)).standardizedFileURL,
            URL.currentDirectory().standardizedFileURL
        )

        try await process.waitUntilExit()
    }

    func testCustomCurrentDirectory() async throws {
        let process = PTYProcess(executablePath: "/bin/pwd", currentDirectory: "/Users/Shared")

        try process.run(stdoutRequest: .pipe)
        var linesIterator = process.stdoutBytes.lines.makeAsyncIterator()

        await XCTAssertEqualAsync(try await linesIterator.next(), "/Users/Shared")

        try await process.waitUntilExit()
    }

    func testEmptyCurrentDirectoryBehavesAsNil() async throws {
        let process = PTYProcess(executablePath: "/bin/pwd", currentDirectory: "")

        try process.run(stdoutRequest: .pipe)
        var linesIterator = process.stdoutBytes.lines.makeAsyncIterator()

        let path = try await linesIterator.next()

        try await XCTAssertEqualAsync(
            URL(fileURLWithPath: XCTUnwrap(path)).standardizedFileURL,
            URL.currentDirectory().standardizedFileURL
        )

        try await process.waitUntilExit()
    }

    func testInterrupt() async throws {
        let process = PTYProcess(executablePath: "/bin/sleep", arguments: ["100"])

        try process.run(signalMask: 0)

        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 5)

        await self.assertIsRunning(process)

        try await process.interrupt()

        await XCTAssertEqualAsync(try await process.waitUntilExit(), .uncaughtSignal(SIGINT))
        await XCTAssertEqualAsync(await process.status, .uncaughtSignal(SIGINT))
    }

    func testTerminate() async throws {
        let process = PTYProcess(executablePath: "/bin/sleep", arguments: ["100"])

        try process.run(signalMask: 0)

        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 5)

        await self.assertIsRunning(process)

        try await process.terminate()

        await XCTAssertEqualAsync(try await process.waitUntilExit(), .uncaughtSignal(SIGTERM))
        await XCTAssertEqualAsync(await process.status, .uncaughtSignal(SIGTERM))
    }

    func testSuspendAndResume() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-i"])

        try process.run(signalMask: 0)
        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 5)
        await self.assertIsRunning(process)

        try await process.suspend()
        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 5)
        await self.assertIsSuspended(process)

        try await process.resume()
        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 5)
        await self.assertIsRunning(process)

        try await process.suspend()
        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 5)
        await self.assertIsSuspended(process)

        try process.ptyHandle?.write(contentsOf: "exit\n".data(using: .ascii)!)
        try await Task.sleep(nanoseconds: NSEC_PER_SEC)
        await self.assertIsSuspended(process)

        try await process.resume()
        try await process.waitUntilExit()

        await XCTAssertEqualAsync(await process.status, .exited(0))
    }

    func testRequestNullStdout() async throws {
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-c", "/usr/bin/env; /usr/bin/env >&2"])

        try process.run(stdoutRequest: .null, stderrRequest: .pipe)

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

        try process.run(stdoutRequest: .pipe, stderrRequest: .null)

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

        try process.run(stdoutRequest: .null, stderrRequest: .null)

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

        try process1.run(stdoutRequest: .pipe, stderrRequest: .null)

        let originalLineCount = try await process1.stdoutBytes.lines.reduce(0) { count, _ in count + 1 }

        let extraFDs = try (0..<8).map { _ in try FileDescriptor.standardOutput.duplicate() }
        defer { extraFDs.forEach { _ = try? $0.close() } }

        let process2 = PTYProcess(executablePath: "/bin/dash", arguments: ["-c", "/usr/sbin/lsof -p $$"])

        try process2.run(stdoutRequest: .pipe, stderrRequest: .null)

        let newLineCount = try await process2.stdoutBytes.lines.reduce(0) { count, _ in count + 1 }

        XCTAssertEqual(originalLineCount, newLineCount)
    }

    func testProcessGroup() async throws {
        // The process group of the child process should be different to the parent's.
        let process = PTYProcess(executablePath: "/bin/sh", arguments: ["-c", "/bin/ps -p $$ -o pgid="])

        try process.run(stdoutRequest: .pipe, stderrRequest: .null)

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
}
