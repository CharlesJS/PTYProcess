//
//  PTYProcess.swift
//
//  Created by Charles Srstka on 5/30/18.
//  Copyright © 2018-2023 Charles Srstka. All rights reserved.
//

import Dispatch
import System

public class PTYProcess {
    public enum Status {
        case notRunYet
        case running(pid_t)
        case terminated(Int32)
        case errorOccurred(Error)
    }

    internal class FileDescriptorWrapper {
        let rawDescriptor: CInt

        @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
        var fileDescriptor: FileDescriptor { FileDescriptor(rawValue: self.rawDescriptor) }

        init(rawDescriptor: CInt) {
            self.rawDescriptor = rawDescriptor
        }

        deinit {
            close(self.rawDescriptor)
        }
    }

    @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    public init(
        executablePath: FilePath,
        arguments: [String] = [],
        environment: [String : String]? = nil
    ) {
        self._executablePath = .filePath(executablePath)
        self.arguments = arguments
        self.environment = environment
    }

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String : String]? = nil
    ) {
        self._executablePath = Path.string(executablePath)
        self.arguments = arguments
        self.environment = environment
    }

    private enum Path {
        case filePath(Any)
        case string(String)

        func withCString<Result>(_ body: (UnsafePointer<Int8>) throws -> Result) rethrows -> Result {
            switch self {
            case .filePath(let path):
                if #available(macOS 12.0, macCatalyst 15.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
                    return try (path as! FilePath).withPlatformString(body)
                } else if #available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) {
                    return try (path as! FilePath).withCString(body)
                } else {
                    preconditionFailure("Should never get here")
                }
            case .string(let string):
                if #available(macOS 12.0, macCatalyst 15.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *) {
                    return try string.withPlatformString(body)
                } else {
                    return try string.withCString(body)
                }
            }
        }
    }

    private let _executablePath: Path

    @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    public var executablePath: FilePath {
        switch self._executablePath {
        case .filePath(let path):
            return path as! FilePath
        case .string(let string):
            return FilePath(string)
        }
    }

    public var rawExecutablePath: String {
        switch self._executablePath {
        case .filePath(let path):
            if #available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) {
                return String(decoding: path as! FilePath)
            } else {
                preconditionFailure("Shouldn't get here")
            }
        case .string(let string):
            return string
        }
    }

    public let arguments: [String]
    public let environment: [String : String]?

    public var status: Status {
        get async {
            guard let runner = self.runner else { return .notRunYet }

            switch await runner.result {
            case .none:
                return .running(runner.processIdentifier)
            case .success(let status):
                return .terminated(status)
            case .failure(let error):
                return .errorOccurred(error)
            }
        }
    }

    private var stdoutRequest: CaptureRequest? = nil
    private var stderrRequest: CaptureRequest? = nil

    private var pipe: FileDescriptorWrapper? = nil
    private var _pty: FileDescriptorWrapper? = nil

    private var _stdout: FileDescriptorWrapper? {
        switch self.stdoutRequest ?? .none {
        case .none:
            return nil
        case .pty:
            return self._pty
        case .pipe:
            return self.pipe
        }
    }

    private var _stderr: FileDescriptorWrapper? {
        switch self.stderrRequest ?? .none {
        case .none:
            return nil
        case .pty:
            return self._pty
        case .pipe:
            return self.pipe
        }
    }

    @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    public var pty: FileDescriptor? { self._pty?.fileDescriptor }

    @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    public var stdout: FileDescriptor? { self._stdout?.fileDescriptor }

    @available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    public var stderr: FileDescriptor? { self._stderr?.fileDescriptor }

    public var rawPTY: CInt? { self._pty?.rawDescriptor }
    public var rawStdout: CInt? { self._stdout?.rawDescriptor }
    public var rawStderr: CInt? { self._stderr?.rawDescriptor }

    private var runner: Runner? = nil

    public enum CaptureRequest {
        case none
        case pipe
        case pty
    }

    public func run(
        stdoutRequest: CaptureRequest = .pty,
        stderrRequest: CaptureRequest = .pty,
        allowReading: Bool = true,
        allowWriting: Bool = true,
        canonicalMode: Bool = true
    ) throws {
        precondition(self.runner == nil, "Cannot run PTYProcess more than once")

        let runner = try self._executablePath.withCString {
            try Runner(
                path: $0,
                arguments: self.arguments,
                environment: self.environment,
                stdoutRequest: stdoutRequest,
                stderrRequest: stderrRequest,
                allowReading: allowReading,
                allowWriting: allowWriting,
                canonicalMode: canonicalMode
            )
        }

        self.runner = runner

        Task(priority: .userInitiated) {
            await runner.startWatching()
        }
    }

    @discardableResult
    public func waitUntilExit() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.runner?.addContinuation(continuation)
            }
        }
    }
}
