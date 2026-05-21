import Accelerate
import AVFoundation

// Phase 1: energy-based VAD. Phase 2: swap in CoreML Silero VAD model.
actor VoiceActivityDetector {
  enum Decision { case speech, silence }

  private let energyThreshold: Float = SpeakerIdentityConfig.vadEnergyThresholdRMS

  // Returns .speech when the RMS energy of `samples` exceeds the threshold.
  // Samples must already be at the target sample rate (16 kHz), mono, float32.
  func classify(samples: [Float]) -> Decision {
    rms(samples) > energyThreshold ? .speech : .silence
  }

  private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sumSquares: Float = 0
    vDSP_svesq(samples, 1, &sumSquares, vDSP_Length(samples.count))
    return sqrt(sumSquares / Float(samples.count))
  }
}
