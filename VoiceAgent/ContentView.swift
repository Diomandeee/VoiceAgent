import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "star.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Voice Agent")
                    .font(.largeTitle.bold())

                Text("Welcome to Voice Agent")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Voice Agent")
        }
    }
}

#Preview {
    ContentView()
}
