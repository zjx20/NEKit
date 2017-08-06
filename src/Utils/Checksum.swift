import Foundation

open class Checksum {

    open static func computeChecksum(_ data: Data, from start: Int = 0, to end: Int? = nil, withPseudoHeaderChecksum initChecksum: UInt32 = 0) -> UInt16 {
        return 0
    }

    open static func validateChecksum(_ payload: Data, from start: Int = 0, to end: Int? = nil) -> Bool {
        let cs = computeChecksumUnfold(payload, from: start, to: end)
        return toChecksum(cs) == 0
    }

    open static func computeChecksumUnfold(_ data: Data, from start: Int = 0, to end: Int? = nil, withPseudoHeaderChecksum initChecksum: UInt32 = 0) -> UInt32 {
        return 0
    }

    open static func toChecksum(_ checksum: UInt32) -> UInt16 {
        return 0
    }
}
