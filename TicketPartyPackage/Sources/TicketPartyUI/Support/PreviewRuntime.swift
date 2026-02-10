import Foundation

enum PreviewRuntime {
    static var usesStubData: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
