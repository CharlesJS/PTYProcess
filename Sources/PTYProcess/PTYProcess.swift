//
//  PTYProcess.swift
//
//  Created by Charles Srstka on 5/30/18.
//  Copyright © 2018-2023 Charles Srstka. All rights reserved.
//

import System
import AsyncAlgorithms
import CSErrors

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public class PTYProcess {
    public enum Status: Equatable {
        case notRunYet
        case running(pid_t)
        case suspended(Int32)
        case exited(Int32)
        case uncaughtSignal(Int32)

        public static func ==(lhs: PTYProcess.Status, rhs: PTYProcess.Status) -> Bool {
            switch lhs {
            case .notRunYet:
                guard case .notRunYet = rhs else { return false }
                return true
            case .running(let lPid):
                guard case .running(let rPid) = rhs else { return false }
                return lPid == rPid
            case .suspended(let lPid):
                guard case .suspended(let rPid) = rhs else { return false }
                return lPid == rPid
            case .exited(let lStatus):
                guard case .exited(let rStatus) = rhs else { return false }
                return lStatus == rStatus
            case .uncaughtSignal(let lSig):
                guard case .uncaughtSignal(let rSig) = rhs else { return false }
                return lSig == rSig
            }
        }
    }

    public struct AsyncBytes: AsyncSequence {
        private static let defaultCapacity = 1024 * 1024 * 1024

        public typealias Element = UInt8

        private let fileDescriptor: FileDescriptorWrapper
        private let capacity: Int

        internal init(fileDescriptor: FileDescriptorWrapper, capacity: Int = AsyncBytes.defaultCapacity) {
            self.fileDescriptor = fileDescriptor
            self.capacity = capacity
        }

        public func makeAsyncIterator() -> AsyncBufferedByteIterator {
            AsyncBufferedByteIterator(capacity: self.capacity) { ptr in
                try await Task {
                    try self.fileDescriptor.readBytes(into: ptr)
                }.value
            }
        }
    }

    internal class FileDescriptorWrapper {
        private enum Storage {
            case fileDescriptor(Any)
            case raw(Int32)

            func closeFile() {
                switch self {
                case .fileDescriptor(let fd):
                    guard #available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) else {
                        preconditionFailure("Should not be reached")
                    }
                    _ = try? (fd as! FileDescriptor).close()
                case .raw(let raw):
                    close(raw)
                }
            }
        }

        @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
        init(fileDescriptor: FileDescriptor) {
            self.storage = .fileDescriptor(fileDescriptor)
        }

        init(rawDescriptor: CInt) {
            self.storage = .raw(rawDescriptor)
        }

        deinit {
            self.storage.closeFile()
        }

        private var storage: Storage

        @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
        var fileDescriptor: FileDescriptor {
            switch self.storage {
            case .fileDescriptor(let fd):
                return fd as! FileDescriptor
            case .raw(let raw):
                return FileDescriptor(rawValue: raw)
            }
        }

        var rawDescriptor: Int32 {
            switch self.storage {
            case .fileDescriptor(let fd):
                guard #available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) else {
                    preconditionFailure("Should not be reached")
                }

                return (fd as! FileDescriptor).rawValue
            case .raw(let raw):
                return raw
            }
        }

        func getBytes(capacity: Int) -> AsyncBytes {
            AsyncBytes(fileDescriptor: self, capacity: capacity)
        }

        func readBytes(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            if #available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) {
                return try self.fileDescriptor.read(into: buffer)
            } else {
                return read(self.rawDescriptor, buffer.baseAddress, buffer.count)
            }
        }
    }

    @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    public init(
        executablePath: FilePath,
        arguments: [String] = [],
        environment: [String : String]? = nil,
        currentDirectory: FilePath? = nil
    ) {
        self._executablePath = .filePath(executablePath)
        self.arguments = arguments
        self.environment = environment
        self._currentDirectory = currentDirectory.map { .filePath($0) }
    }

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String : String]? = nil,
        currentDirectory: String? = nil
    ) {
        self._executablePath = .string(executablePath)
        self.arguments = arguments
        self.environment = environment
        self._currentDirectory = currentDirectory.map { .string($0) }
    }

    private enum Path {
        case filePath(Any)
        case string(String)

        @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
        var asFilePath: FilePath {
            switch self {
            case .filePath(let path):
                return path as! FilePath
            case .string(let string):
                return FilePath(string)
            }
        }

        var asString: String {
            switch self {
            case .filePath(let path):
                if #available(macOS 12.0, macCatalyst 15.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
                    return (path as! FilePath).string
                } else if #available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) {
                    return String(decoding: path as! FilePath)
                } else {
                    preconditionFailure("Should never be reached")
                }
            case .string(let string):
                return string
            }
        }

        func withCString<Result>(_ body: (UnsafePointer<Int8>) throws -> Result) rethrows -> Result {
            if #available(macOS 12.0, macCatalyst 15.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
                return try self.asFilePath.withPlatformString(body)
            } else if #available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) {
                return try self.asFilePath.withCString(body)
            } else {
                return try self.asString.withCString(body)
            }
        }
    }

    private let _executablePath: Path
    private let _currentDirectory: Path?

    @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    public var executablePath: FilePath { self._executablePath.asFilePath }
    public var rawExecutablePath: String { self._executablePath.asString }

    public let arguments: [String]
    public let environment: [String : String]?

    @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    public var currentDirectory: FilePath? { self._currentDirectory?.asFilePath }
    public var rawCurrentDirectory: String? { self._currentDirectory?.asString }

    public var status: Status {
        get async {
            guard let watcher = self.watcher else { return .notRunYet }

            return await watcher.status
        }
    }

    private var _pty: FileDescriptorWrapper? { self.runner?.pty }
    private var _stdout: FileDescriptorWrapper? { self.runner?.stdout }
    private var _stderr: FileDescriptorWrapper? { self.runner?.stderr }

    @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    public var pty: FileDescriptor? { self._pty?.fileDescriptor }

    @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    public var stdout: FileDescriptor? { self._stdout?.fileDescriptor }

    @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    public var stderr: FileDescriptor? { self._stderr?.fileDescriptor }

    public var rawPTY: CInt? { self._pty?.rawDescriptor }
    public var rawStdout: CInt? { self._stdout?.rawDescriptor }
    public var rawStderr: CInt? { self._stderr?.rawDescriptor }
    
    public var ptyBytes: AsyncBytes {
        guard let fd = self._pty else {
            fatalError("ptyBytes called on PTYProcess for which no PTY was requested")
        }

        return AsyncBytes(fileDescriptor: fd)
    }

    public var stdoutBytes: AsyncBytes {
        guard let fd = self._stdout else {
            fatalError("stdoutBytes called on PTYProcess for which stdout was not requested")
        }

        return AsyncBytes(fileDescriptor: fd)
    }

    public var stderrBytes: AsyncBytes {
        guard let fd = self._stderr else {
            fatalError("stderrBytes called on PTYProcess for which stderr was not requested")
        }

        return AsyncBytes(fileDescriptor: fd)
    }

    public var ptyOptions: PTYOptions {
        get throws {
            guard let pty = self.rawPTY else { throw errno(EBADF) }
            return try PTYOptions(fileDescriptor: pty)
        }
    }

    public func setPTYOptions(_ options: PTYOptions, immediately: Bool = false, drainFirst: Bool = false) throws {
        guard let pty = self.rawPTY else { throw errno(EBADF) }
        try options.apply(to: pty, immediately: immediately, drainFirst: drainFirst)
    }

    private var runner: Runner? = nil
    private var watcher: Watcher? = nil

    public enum CaptureRequest {
        case null
        case pipe
        case pty
    }

    public func run(
        stdoutRequest: CaptureRequest? = .pty,
        stderrRequest: CaptureRequest? = .pty,
        options: PTYOptions = [],
        signalMask: sigset_t? = nil
    ) async throws {
        precondition(self.runner == nil && self.watcher == nil, "Cannot run PTYProcess more than once")

        func withCurrentDirectory(closure: (UnsafePointer<CChar>?) throws -> Runner) rethrows -> Runner {
            if let currentDirectory = self._currentDirectory {
                return try currentDirectory.withCString(closure)
            } else {
                return try closure(nil)
            }
        }

        let runner = try self._executablePath.withCString { path in
            try withCurrentDirectory { currentDirectory in
                try Runner(
                    path: path,
                    arguments: self.arguments,
                    environment: self.environment,
                    currentDirectory: currentDirectory,
                    stdoutRequest: stdoutRequest,
                    stderrRequest: stderrRequest,
                    options: options,
                    signalMask: signalMask
                )
            }
        }

        let watcher = Watcher(processIdentifier: runner.processIdentifier)

        self.runner = runner
        self.watcher = watcher

        await watcher.startWatching()
    }

    public func terminate() async throws {
        try await self.sendSignal(SIGTERM)
    }

    public func interrupt() async throws {
        try await self.sendSignal(SIGINT)
    }

    public func suspend() async throws {
        try await self.watcher?.suspend()
    }

    public func resume() async throws {
        try await self.watcher?.resume()
    }

    private func sendSignal(_ signal: Int32) async throws {
        guard let watcher = self.watcher else { throw errno(ESRCH) }
        try await watcher.sendSignal(signal)
    }

    @discardableResult
    public func waitUntilExit() async throws -> Status {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.watcher?.addContinuation(continuation)
            }
        }
    }
}
