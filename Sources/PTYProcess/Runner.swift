//
//  Runner.swift
//  
//
//  Created by Charles Srstka on 1/20/22.
//

import CSErrors

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension PTYProcess {
    internal class Runner {
        let processIdentifier: pid_t

        let pty: FileDescriptorWrapper
        let stdout: FileDescriptorWrapper?
        let stderr: FileDescriptorWrapper?

        init(
            path: UnsafePointer<Int8>,
            arguments: [String],
            environment: [String : String]?,
            currentDirectory: UnsafePointer<Int8>?,
            stdoutRequest: CaptureRequest?,
            stderrRequest: CaptureRequest?,
            options: PTYOptions,
            signalMask: sigset_t?
        ) throws {
            var closeOnError: [Int32] = []

            do {
                let (primary: primaryPTY, secondary: secondaryPTY) = try Self.openPTYPair(options: options)

                var closeOnExit: [Int32] = []
                defer { closeOnExit.forEach { close($0) } }

                var actions: posix_spawn_file_actions_t? = nil
                if posix_spawn_file_actions_init(&actions) != 0 { throw errno() }
                defer { posix_spawn_file_actions_destroy(&actions) }

                if posix_spawn_file_actions_addclose(&actions, primaryPTY) != 0 ||
                    posix_spawn_file_actions_adddup2(&actions, secondaryPTY, STDIN_FILENO) != 0 {
                    throw errno()
                }

                // chdir gives ENOENT if the current directory is empty, so treat empty string as a nil here
                if let currentDirectory, currentDirectory[0] != 0,
                   posix_spawn_file_actions_addchdir_np(&actions, currentDirectory) != 0 {
                    throw errno()
                }

                var attrs: posix_spawnattr_t? = nil
                if case let err = posix_spawnattr_init(&attrs), err != 0 {
                    throw errno(err)
                }

                defer { posix_spawnattr_destroy(&attrs) }

                if case let err = posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP)), err != 0 {
                    throw errno(err)
                }

                if var signalMask {
                    if case let err = posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSIGMASK)), err != 0 {
                        throw errno(err)
                    }

                    if case let err = posix_spawnattr_setsigmask(&attrs, &signalMask), err != 0 {
                        throw errno(err)
                    }
                }

                self.pty = FileDescriptorWrapper(rawDescriptor: primaryPTY)

                self.stdout = try Self.setUpChannel(
                    request: stdoutRequest,
                    fd: STDOUT_FILENO,
                    primaryPTY: primaryPTY,
                    secondaryPTY: secondaryPTY,
                    actions: &actions,
                    closeOnExit: &closeOnExit,
                    closeOnError: &closeOnError
                )

                self.stderr = try Self.setUpChannel(
                    request: stderrRequest,
                    fd: STDERR_FILENO,
                    primaryPTY: primaryPTY,
                    secondaryPTY: secondaryPTY,
                    actions: &actions,
                    closeOnExit: &closeOnExit,
                    closeOnError: &closeOnError
                )

                closeOnError.append(primaryPTY)
                closeOnExit.append(secondaryPTY)

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
                    let err = posix_spawn(&pid, path, &actions, &attrs, argv, envp)

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

        private static func openPTYPair(options: PTYOptions) throws -> (primary: Int32, secondary: Int32) {
            let primary = posix_openpt(O_RDWR)

            if primary < 0 || grantpt(primary) != 0 || unlockpt(primary) != 0 { throw errno() }
            let secondary = open(ptsname(primary), O_RDWR | O_NOCTTY)

            if secondary < 0 { throw errno() }
            
            try options.apply(to: primary, immediately: true, drainFirst: false)

            return (primary: primary, secondary: secondary)
        }

        private static func swiftStrdup(_ str: UnsafePointer<Int8>) -> UnsafeMutablePointer<Int8> {
            let len = strlen(str)
            let newString = UnsafeMutablePointer<Int8>.allocate(capacity: len + 1)
            newString.assign(from: str, count: len)
            newString[len] = 0
            return newString
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
            request: CaptureRequest?,
            fd: Int32,
            primaryPTY: Int32,
            secondaryPTY: Int32,
            actions: inout posix_spawn_file_actions_t?,
            closeOnExit: inout [Int32],
            closeOnError: inout [Int32]
        ) throws -> FileDescriptorWrapper? {
            switch request {
            case .none:
                return nil
            case .null:
                if #available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) {
                    return try .init(fileDescriptor: .open("/dev/null", .readWrite))
                } else {
                    return .init(rawDescriptor: open("/dev/null", O_RDWR))
                }
            case .pty:
                if posix_spawn_file_actions_adddup2(&actions, secondaryPTY, fd) != 0 {
                    throw errno()
                }

                return FileDescriptorWrapper(rawDescriptor: primaryPTY)
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

                return FileDescriptorWrapper(rawDescriptor: fds[0])
            }
        }
    }
}
