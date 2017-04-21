import Foundation

struct GlobalIntializer {
    private static let _initialized: Bool = {
        
        return true
    }()

    static func initalize() {
        _ = _initialized
    }
}
