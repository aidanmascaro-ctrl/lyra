import SwiftUI

/// Lyra › Settings… (⌘,).
struct SettingsPage: View {
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(Chrome.titleFont).padding(.bottom, 8)
            Toggle("Open Lyra when you log in", isOn: Binding(get: { loginItem.state.isOn }, set: loginItem.set))
                .toggleStyle(.switch)
            Text("Lyra opens each time you log in to your Mac, so it's ready to record.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if loginItem.state == .needsApproval {
                HStack {
                    Text("macOS needs you to allow Lyra in Login Items.").font(.callout)
                    Button("Open Login Items…") { loginItem.openSystemSettings() }
                }
            }
            if let error = loginItem.error { Text(error).font(.callout).foregroundStyle(Chrome.record) }
        }
        .padding(.horizontal, 24)
        .padding(.top, Chrome.topInset)
        .padding(.bottom, 24)
        .frame(width: 420, alignment: .leading)
        .lyraWindow()
        .onAppear { loginItem.refresh() }
    }
}
