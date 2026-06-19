import SwiftUI

struct StreamSessionView: View {
  @StateObject private var viewModel = StreamSessionViewModel()

  var body: some View {
    Group {
      if viewModel.isStreaming {
        PowerSavingStreamView()
      } else {
        NonStreamView(viewModel: viewModel)
          .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") {
              viewModel.dismissError()
            }
          } message: {
            Text(viewModel.errorMessage)
          }
          .sheet(isPresented: $viewModel.showPeopleDictionary) {
            PeopleDictionaryView(viewModel: viewModel)
          }
          .sheet(isPresented: $viewModel.showStreamSummaryHistory) {
            StreamSummaryHistoryView(viewModel: viewModel)
          }
      }
    }
  }
}

private struct PowerSavingStreamView: View {
  var body: some View {
    Color.black
      .ignoresSafeArea()
      .persistentSystemOverlays(.hidden)
      .accessibilityIdentifier("power_saving_stream_surface")
  }
}
