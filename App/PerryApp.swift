import SwiftUI

@main
struct PerryApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("Perry")
                    .font(.largeTitle.bold())
                Text("Milestone 1 skeleton")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 320, height: 180)
        }
    }
}
