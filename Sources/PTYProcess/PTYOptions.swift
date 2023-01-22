//
//  PTYOptions.swift
//  
//
//  Created by Charles Srstka on 1/6/23.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import CSErrors

extension PTYProcess {
    public struct PTYOptions: OptionSet, Hashable {
        public static let disableEcho = PTYOptions(rawValue: 1 << 1)
        public static let nonCanonical = PTYOptions(rawValue: 1 << 2)
        public static let outputCRLF = PTYOptions(rawValue: 1 << 3)

        private static let attributeMappings: [PTYOptions : AttributeMapping] = [
            .disableEcho: .init(keyPath: \.c_lflag, flag: ECHO, inverted: true),
            .nonCanonical: .init(keyPath: \.c_lflag, flag: ICANON, inverted: true),
            .outputCRLF: .init(keyPath: \.c_oflag, flag: ONLCR, inverted: false)
        ]

        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        internal init(fileDescriptor: Int32) throws {
            let t = try Self.getTermios(fileDescriptor: fileDescriptor)

            var options: PTYOptions = []

            for (option, mapping) in Self.attributeMappings {
                if mapping.isSet(t) {
                    options.insert(option)
                }
            }

            self = options
        }

        internal func apply(to fileDescriptor: Int32, immediately: Bool, drainFirst: Bool) throws {
            var t = try Self.getTermios(fileDescriptor: fileDescriptor)

            for (option, mapping) in Self.attributeMappings {
                mapping.set(&t, state: self.contains(option))
            }

            try Self.setTermios(t, fileDescriptor: fileDescriptor, immediately: immediately, drainFirst: drainFirst)
        }

        private struct AttributeMapping {
            let keyPath: WritableKeyPath<termios, tcflag_t>
            let flag: Int32
            let inverted: Bool

            func isSet(_ t: termios) -> Bool {
                let isSet = t[keyPath: self.keyPath] & tcflag_t(self.flag) != 0

                return self.inverted ? !isSet : isSet
            }

            func set(_ t: inout termios, state: Bool) {
                if state == inverted {
                    t[keyPath: self.keyPath] &= ~tcflag_t(flag)
                } else {
                    t[keyPath: self.keyPath] |= tcflag_t(flag)
                }
            }
        }

        private static func getTermios(fileDescriptor: Int32) throws -> termios {
            try callPOSIXFunction(expect: .zero) { tcgetattr(fileDescriptor, $0) }
        }

        private static func setTermios(_ t: termios, fileDescriptor: Int32, immediately: Bool, drainFirst: Bool) throws {
            var t = t
            var options: Int32 = 0

            if immediately {
                options |= TCSANOW
            }

            if drainFirst {
                options |= TCSADRAIN
            }

            try callPOSIXFunction(expect: .zero) { tcsetattr(fileDescriptor, options, &t) }
        }
    }
}
