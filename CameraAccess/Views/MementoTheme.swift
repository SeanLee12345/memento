import SwiftUI

enum MementoTheme {
  static let backgroundTop = Color(red: 0.035, green: 0.068, blue: 0.065)
  static let backgroundBottom = Color(red: 0.015, green: 0.016, blue: 0.018)
  static let panel = Color(red: 0.055, green: 0.071, blue: 0.075).opacity(0.78)
  static let panelRaised = Color(red: 0.075, green: 0.096, blue: 0.100).opacity(0.92)
  static let panelBorder = Color.white.opacity(0.11)
  static let primary = Color("appPrimaryColor")
  static let accent = Color.mementoMint
  static let warning = Color.mementoAmber
  static let success = Color.mementoMint
  static let listCardPrimaryText = Color(red: 0.06, green: 0.08, blue: 0.09)
  static let listCardSecondaryText = Color(red: 0.30, green: 0.36, blue: 0.38)
  static let listCardTertiaryText = Color(red: 0.38, green: 0.44, blue: 0.46)
  static let listCardSeparator = Color(red: 0.64, green: 0.70, blue: 0.71)
  static let listCardMutedFill = Color(red: 0.88, green: 0.92, blue: 0.91)

  static var homeBackground: LinearGradient {
    LinearGradient(
      colors: [backgroundTop, backgroundBottom],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

extension Color {
  static let mementoMint = Color(red: 0.31, green: 0.86, blue: 0.62)
  static let mementoAmber = Color(red: 1.0, green: 0.72, blue: 0.25)
  static let mementoCoral = Color(red: 1.0, green: 0.37, blue: 0.32)
  static let mementoListCard = Color(red: 0.95, green: 0.98, blue: 0.97)
}

extension View {
  func mementoPanel(cornerRadius: CGFloat = 8) -> some View {
    self
      .background(MementoTheme.panel)
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius)
          .stroke(MementoTheme.panelBorder, lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
  }
}
