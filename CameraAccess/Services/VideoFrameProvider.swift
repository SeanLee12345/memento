import CoreMedia

protocol VideoFrameProvider: AnyObject {
  var onFrame: ((CMSampleBuffer) -> Void)? { get set }

  func start()
  func stop()
}

