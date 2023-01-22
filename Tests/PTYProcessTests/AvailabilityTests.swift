//
//  AvailabilityTests.swift
//  
//
//  Created by Charles Srstka on 1/22/23.
//

import CwlPreconditionTesting
@testable import PTYProcess
import System
import XCTest

@available(macOS 13.0, *)
class BigSurTests: PTYProcessTests {
    override func setUp() async throws {
        emulateMacOSVersion(11)
    }

    override func tearDown() async throws {
        resetMacOSVersion()
    }
}

@available(macOS 13.0, *)
class MacOSXTests: PTYProcessTests {
    override class var supportsFilePath: Bool { false }

    override func setUp() async throws {
        emulateMacOSVersion(10)
    }

    override func tearDown() async throws {
        resetMacOSVersion()
    }

    func testHopefullyUnreachableFilePathFailure() async throws {
        let process = PTYProcess(executablePath: FilePath("/usr/bin/true"))

        XCTAssertNotNil(catchBadInstruction { _ = process.rawExecutablePath })
    }
}
