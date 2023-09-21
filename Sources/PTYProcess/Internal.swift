//
//  Internal.swift
//  
//
//  Created by Charles Srstka on 1/22/23.
//

#if DEBUG
// These functions are to be used during testing only!
func emulateMacOSVersion(_ vers: Int) {
    emulatedVersion = vers
}

func resetMacOSVersion() {
    emulatedVersion = Int.max
}

private var emulatedVersion = Int.max
package func versionCheck(_ vers: Int) -> Bool { emulatedVersion >= vers }
#else
@inline(__always) package func versionCheck(_ vers: Int) -> Bool { true }
#endif
