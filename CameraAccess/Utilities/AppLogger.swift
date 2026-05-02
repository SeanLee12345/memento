import Foundation

enum AppLogCategory: String {
  case sdk = "SDK"
  case registration = "REGISTRATION"
  case permissions = "PERMISSIONS"
  case devices = "DEVICES"
  case stream = "STREAM"
  case frames = "FRAMES"
  case vision = "VISION"
  case audio = "AUDIO"
  case mock = "MOCK"
  case tests = "TESTS"
}

enum AppLogger {
  static func log(_ category: AppLogCategory, _ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    print("[MetaFace][\(timestamp)][\(category.rawValue)] \(message)")
  }
}
