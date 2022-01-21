//
//  PTYProcessRunner.swift
//  
//
//  Created by Charles Srstka on 1/20/22.
//

import CSErrors
import Dispatch
import System

// Macros from sys/wait that unfortunately aren't exposed to Swift
private func _WSTATUS(_ x: Int32) -> Int32 { x & 0o177 }
private func WIFEXITED(_ x: Int32) -> Bool { _WSTATUS(x) == 0 }
private func WEXITSTATUS(_ x: Int32) -> Int32 { (x >> 8) & 0xff }

extension PTYProcess {
    internal actor Runner {
        private enum Channel {
            case none
            case pty
            case pipe(FileDescriptorWrapper)

            func getFileDescriptor(pty: FileDescriptorWrapper) -> FileDescriptorWrapper? {
                switch self {
                case .none:
                    return nil
                case .pty:
                    return pty
                case .pipe(let fd):
                    return fd
                }
            }
        }

        private let stdoutChannel: Channel
        private let stderrChannel: Channel

        let processIdentifier: pid_t
        var result: Result<Int32, Error>? = nil

        let pty: FileDescriptorWrapper
        var stdout: FileDescriptorWrapper? { self.stdoutChannel.getFileDescriptor(pty: self.pty) }
        var stderr: FileDescriptorWrapper? { self.stderrChannel.getFileDescriptor(pty: self.pty) }

        init(
            path: UnsafePointer<Int8>,
            arguments: [String],
            environment: [String : String]?,
            stdoutRequest: CaptureRequest,
            stderrRequest: CaptureRequest,
            allowReading: Bool,
            allowWriting: Bool,
            canonicalMode: Bool
        ) throws {
            var closeOnError: [Int32] = []

            do {
                var closeOnExit: [Int32] = []
                defer { closeOnExit.forEach { close($0) } }

                var actions: posix_spawn_file_actions_t? = nil
                if posix_spawn_file_actions_init(&actions) != 0 { throw errno() }
                defer { posix_spawn_file_actions_destroy(&actions) }

                let (primary: primary, secondary: secondary) = try Self.openPTYPair()

                if posix_spawn_file_actions_addclose(&actions, primary) != 0 ||
                    posix_spawn_file_actions_adddup2(&actions, secondary, STDIN_FILENO) != 0 {
                    throw errno()
                }

                self.stdoutChannel = try Self.setUpChannel(
                    request: stdoutRequest,
                    fd: STDOUT_FILENO,
                    secondary: secondary,
                    actions: &actions,
                    closeOnExit: &closeOnExit,
                    closeOnError: &closeOnError
                )

                self.stderrChannel = try Self.setUpChannel(
                    request: stderrRequest,
                    fd: STDERR_FILENO,
                    secondary: secondary,
                    actions: &actions,
                    closeOnExit: &closeOnExit,
                    closeOnError: &closeOnError
                )

                self.pty = FileDescriptorWrapper(rawDescriptor: primary)

                closeOnError.append(primary)
                closeOnExit.append(secondary)

                let argc = arguments.count + 1
                let argv = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: argc + 1)

                defer {
                    for i in 0..<argc {
                        argv[i]?.deallocate()
                    }

                    argv.deallocate()
                }

                argv[0] = Self.swiftStrdup(path)

                for (i, eachArg) in arguments.enumerated() {
                    argv[i + 1] = eachArg.withCString { Self.swiftStrdup($0) }
                }

                argv[argc] = nil

                var pid: pid_t = 0

                try Self.withEnvironmentPointer(for: environment) { envp in
                    let err = posix_spawn(&pid, path, &actions, nil, argv, envp)

                    if err != 0 {
                        throw errno()
                    }
                }

                self.processIdentifier = pid
            } catch {
                closeOnError.forEach { close($0) }

                throw error
            }
        }

        private static func swiftStrdup(_ str: UnsafePointer<Int8>) -> UnsafeMutablePointer<Int8> {
            let len = strlen(str)
            let newString = UnsafeMutablePointer<Int8>.allocate(capacity: len + 1)
            newString.assign(from: str, count: len)
            newString[len] = 0
            return newString
        }

        private static func openPTYPair() throws -> (primary: Int32, secondary: Int32) {
            let primary = posix_openpt(O_RDWR)

            if primary < 0 || grantpt(primary) != 0 || unlockpt(primary) != 0 { throw errno() }

            let secondary = open(ptsname(primary), O_RDWR | O_NOCTTY)

            if secondary < 0 { throw errno() }

            return (primary: primary, secondary: secondary)
        }

        private static func withEnvironmentPointer(
            for environment: [String : String]?,
            _ body: (UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>) throws -> ()
        ) rethrows {
            if let environment = environment {
                let envc = environment.count
                let envp = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: envc + 1)

                defer {
                    for i in 0..<envc {
                        envp[i]?.deallocate()
                    }

                    envp.deallocate()
                }

                for (i, (key: key, value: value)) in environment.enumerated() {
                    envp[i] = "\(key)=\(value)".withCString { Self.swiftStrdup($0) }
                }

                envp[envc] = nil

                try body(envp)
            } else {
                try body(environ)
            }
        }

        private static func setUpChannel(
            request: CaptureRequest,
            fd: Int32,
            secondary: Int32,
            actions: inout posix_spawn_file_actions_t?,
            closeOnExit: inout [Int32],
            closeOnError: inout [Int32]
        ) throws -> Channel {
            switch request {
            case .none:
                return .none
            case .pty:
                if posix_spawn_file_actions_adddup2(&actions, secondary, fd) != 0 {
                    throw errno()
                }

                return .pty
            case .pipe:
                var fds: [Int32] = [0, 0]
                try fds.withUnsafeMutableBufferPointer {
                    if Darwin.pipe($0.baseAddress!) != 0 { throw errno() }
                }

                closeOnExit.append(fds[1])
                closeOnError.append(fds[0])

                if posix_spawn_file_actions_addclose(&actions, fds[0]) != 0 ||
                    posix_spawn_file_actions_adddup2(&actions, fds[1], fd) != 0 {
                    throw errno()
                }

                return .pipe(FileDescriptorWrapper(rawDescriptor: fds[0]))
            }
        }

        private var continuations: [CheckedContinuation<Int32, Error>] = []

        func addContinuation(_ continuation: CheckedContinuation<Int32, Error>) {
            if let result = self.result {
                continuation.resume(with: result)
            } else {
                self.continuations.append(continuation)
            }
        }

        private var signalSource: DispatchSourceSignal? = nil
        func startWatching() {
            let signalSource = DispatchSource.makeSignalSource(signal: SIGCHLD)
            self.signalSource = signalSource

            signalSource.setEventHandler {
                Task(priority: .userInitiated) {
                    self.eventHandler()
                }
            }

            signalSource.activate()
        }

        private func eventHandler() {
            self.signalSource?.setEventHandler(handler: nil)
            self.signalSource?.cancel()
            self.signalSource = nil

            var status: Int32 = 0

            if waitpid(self.processIdentifier, &status, WNOHANG) < 0 {
                self.notify(result: .failure(errno()))
                return
            }

            if WIFEXITED(status) {
                self.notify(result: .success(WEXITSTATUS(status)))
            }
        }

        private func notify(result: Result<Int32, Error>) {
            self.result = result
            
            for eachContinuation in self.continuations {
                eachContinuation.resume(with: result)
            }

            self.continuations.removeAll()
        }
    }
}
