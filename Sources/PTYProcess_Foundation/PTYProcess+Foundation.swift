//
//  PTYProcess+Foundation.swift
//  
//
//  Created by Charles Srstka on 1/2/23.
//

import Foundation
import System
import PTYProcess

extension PTYProcess {
    public convenience init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String : String]? = nil,
        currentDirectory: URL? = nil
    ) throws {
        guard executableURL.isFileURL else {
            throw POSIXError(.EINVAL)
        }

        if #available(macOS 11.0, macCatalyst 14.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) {
            self.init(
                executablePath: FilePath(executableURL.path),
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory.map { FilePath($0.path) }
            )
        } else {
            self.init(
                executablePath: executableURL.path,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory?.path
            )
        }
    }

    public var ptyHandle: FileHandle? {
        self.rawPTY.map { FileHandle(fileDescriptor: $0, closeOnDealloc: false) }
    }

    public var stdoutHandle: FileHandle? {
        self.rawStdout.map { FileHandle(fileDescriptor: $0, closeOnDealloc: false) }
    }

    public var stderrHandle: FileHandle? {
        self.rawStderr.map { FileHandle(fileDescriptor: $0, closeOnDealloc: false) }
    }
}
