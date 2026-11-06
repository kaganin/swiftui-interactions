import SwiftUI

@main
struct StarterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Starter")
                .font(.largeTitle.bold())
            Text("Make something worth playing with.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
