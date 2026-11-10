import AppKit
import LyraCore
import SwiftUI

/// "Coming up" on the home page: the week's real meetings from Google and Microsoft calendars, by day. Join on a
/// meeting about to start opens the call, and Lyra records once the meeting app takes the mic.
struct UpcomingSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var calendar = CalendarModel.shared
    @State private var microsoftID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            banners
            if calendar.ready && !calendar.connected && calendar.signingIn == nil {
                VStack(spacing: 0) {
                    connectRow(.google, "Connect Google Calendar")
                    connectRow(.microsoft, "Connect Microsoft calendar", detail: "Outlook or Microsoft 365")
                }
                .padding(.horizontal, -8)
            } else if calendar.ready && calendar.connected && calendar.days.isEmpty && calendar.problems.isEmpty {
                Text("No meetings in the next week.").font(.system(size: 14)).foregroundStyle(.tertiary)
            }
            ForEach(calendar.days, id: \.date) { day in
                let events = day.events.filter { !isLiveMeeting($0) }
                if !events.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(UpcomingMeetings.label(for: day.date, now: Date()))
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
                        ForEach(events) { row($0) }
                    }
                    .padding(.horizontal, -8)
                }
            }
        }
        .onAppear { calendar.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in calendar.refresh() }
        .task {
            // Drops finished meetings and brings Join forward each minute; asks the calendars again every five.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                calendar.refresh(maxAge: 300)
            }
        }
        .alert("Microsoft app ID", isPresented: $calendar.askingForMicrosoftID) {
            TextField("Application (client) ID", text: $microsoftID)
            Button("Connect") { calendar.useMicrosoftID(microsoftID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the Application (client) ID from App registrations in Microsoft Entra. It looks like 1a2b3c4d-….")
        }
    }

    private var header: some View {
        HStack {
            Text("COMING UP").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
            Spacer()
            if calendar.connected { accountsMenu }
        }
    }

    private var accountsMenu: some View {
        Menu {
            Section("Calendars") {
                ForEach(calendar.accounts) { account in
                    Menu(account.label) { Button("Remove from Lyra") { calendar.remove(account) } }
                }
            }
            Divider()
            Button("Add Google account…") { calendar.connect(.google) }
            Button("Add Microsoft account…") { calendar.connect(.microsoft) }
            Divider()
            Button("Change Google sign-in file…") { calendar.changeAppDetails(.google) }
            Button("Change Microsoft app ID…") { calendar.changeAppDetails(.microsoft) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(calendar.signingIn != nil)
        .help("Calendars")
    }

    @ViewBuilder private var banners: some View {
        if let join = app.pendingJoin {
            Banner(text: "Lyra will record “\(join.title)” as soon as the call has you in.") { Button("Don't record") { app.pendingJoin = nil } }
        }
        if let provider = calendar.signingIn {
            Banner(text: "Finish signing in to \(provider.name) in your browser…", spinning: true) { Button("Cancel") { calendar.cancelSignIn() } }
        }
        if let notice = calendar.notice { Banner(text: notice) { Button("OK") { calendar.notice = nil } } }
        ForEach(calendar.accounts.filter { calendar.problems[$0.id] != nil }) { account in
            let problem = calendar.problems[account.id]!
            Banner(text: "\(account.label): \(problem.message)") {
                if problem.needsSignIn { Button("Reconnect") { calendar.connect(account.provider) } }
                else { Button("Try again") { calendar.refresh(maxAge: 0) } }
            }
        }
    }

    private func connectRow(_ provider: CalendarProvider, _ title: String, detail: String? = nil) -> some View {
        Button { calendar.connect(provider) } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                Text(title)
                if let detail { Text(detail).foregroundStyle(.tertiary) }
                Spacer()
            }
            .font(.system(size: 14)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    /// True for the event that is now showing as the live-recording card on Home, so it isn't listed twice.
    private func isLiveMeeting(_ event: CalendarEvent) -> Bool {
        guard let title = app.liveMeeting?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return false }
        return event.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(title) == .orderedSame
    }

    private func row(_ event: CalendarEvent) -> some View {
        let now = Date()
        let underWay = event.isUnderWay(at: now)
        let joinable = PendingJoin.canArm(event, now: now)
        return Button { calendar.join(event, app: app) } label: {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    if underWay { Circle().fill(Chrome.live).frame(width: 6, height: 6) }
                    Text(underWay ? "Now" : event.start.formatted(date: .omitted, time: .shortened))
                }
                .foregroundStyle(underWay ? .secondary : .tertiary).monospacedDigit()
                .frame(width: 72, alignment: .leading)
                Text(event.title.isEmpty ? "Untitled" : event.title).foregroundStyle(.primary).lineLimit(1)
                if event.otherAttendees > 0 {
                    Text("· \(event.otherAttendees + 1) people").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 12)
                if joinable { joinPill(prominent: underWay) }
                else if event.joinURL != nil { Image(systemName: "video").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 14))
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(event.joinURL == nil)
        .help(event.joinURL == nil ? "No call link in this event"
              : joinable ? "Join the call — Lyra starts recording once you're let in"
              : "Open the call link. Join appears 15 minutes before the start, and records once you're in.")
    }

    private func joinPill(prominent: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "video.fill").font(.system(size: 10))
            Text("Join")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(prominent ? .primary : .secondary)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(Capsule().fill(prominent ? Chrome.live.opacity(0.28) : Chrome.pill))
    }
}
