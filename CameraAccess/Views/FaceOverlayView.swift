import SwiftUI

struct FaceOverlayView: View {
  let faces: [DetectedFace]
  let imageSize: CGSize

  var body: some View {
    GeometryReader { proxy in
      ForEach(faces) { face in
        let rect = displayRect(for: face.boundingBox, in: proxy.size)
        ZStack(alignment: .topLeading) {
          RoundedRectangle(cornerRadius: 4)
            .stroke(Color.green, lineWidth: 3)
            .frame(width: rect.width, height: rect.height)

          Text(face.displayName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.green)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .offset(y: -24)
            .accessibilityIdentifier("face_label_\(face.id)")
        }
        .position(x: rect.midX, y: rect.midY)
        .accessibilityIdentifier("face_box_\(face.id)")
      }
    }
    .allowsHitTesting(false)
  }

  private func displayRect(for normalizedBox: CGRect, in viewSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
      return .zero
    }

    let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    let scaledImageSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let xOffset = (viewSize.width - scaledImageSize.width) / 2
    let yOffset = (viewSize.height - scaledImageSize.height) / 2

    let x = xOffset + normalizedBox.minX * scaledImageSize.width
    let y = yOffset + (1 - normalizedBox.maxY) * scaledImageSize.height
    let width = normalizedBox.width * scaledImageSize.width
    let height = normalizedBox.height * scaledImageSize.height
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
