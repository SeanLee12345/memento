import SwiftUI

struct StreamSessionView: View {
  @StateObject private var viewModel = StreamSessionViewModel()

  var body: some View {
    ZStack {
      if viewModel.isStreaming {
        StreamView(viewModel: viewModel)
      } else {
        NonStreamView(viewModel: viewModel)
      }
    }
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
  }
}
