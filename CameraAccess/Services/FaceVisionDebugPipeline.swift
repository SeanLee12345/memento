import Foundation
import ImageIO
import UIKit

enum FaceVisionDebugPipeline {
  static let sweepOrientations: [CGImagePropertyOrientation] = [
    .up,
    .right,
    .left,
    .down,
    .upMirrored,
    .rightMirrored,
    .leftMirrored,
    .downMirrored
  ]

  static func cgImagePropertyOrientation(from uiOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
    switch uiOrientation {
    case .up:
      return .up
    case .down:
      return .down
    case .left:
      return .left
    case .right:
      return .right
    case .upMirrored:
      return .upMirrored
    case .downMirrored:
      return .downMirrored
    case .leftMirrored:
      return .leftMirrored
    case .rightMirrored:
      return .rightMirrored
    @unknown default:
      return .up
    }
  }

  static func shouldRunOrientationSweep(frame: UInt64, verbose: Bool) -> Bool {
    guard IdentityConfig.enableVisionOrientationSweep else { return false }
    return verbose || frame <= 20 || frame % 30 == 0
  }

  static func orientationCountsText(_ counts: [CGImagePropertyOrientation: Int]) -> String {
    let body = sweepOrientations
      .map { "\($0.debugName):\(counts[$0] ?? 0)" }
      .joined(separator: ",")
    return "{\(body)}"
  }

  static func orientationCountsJSON(_ counts: [CGImagePropertyOrientation: Int]) -> String {
    let body = sweepOrientations
      .map { "\"\($0.debugName)\":\(counts[$0] ?? 0)" }
      .joined(separator: ",")
    return "{\(body)}"
  }

  static func selectionReason(
    selected: CGImagePropertyOrientation,
    mapped: CGImagePropertyOrientation,
    usedSweep: Bool
  ) -> String {
    guard usedSweep else { return "mappedOrientation" }
    return selected == mapped ? "mappedOrientation" : "sweepMax"
  }
}
