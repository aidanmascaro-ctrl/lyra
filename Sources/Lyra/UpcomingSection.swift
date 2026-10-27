import AppKit
import LyraCore
import SwiftUI

/// "Coming up" on the home page: the week's real meetings from Google Calendar, by day. A meeting with a call link
/// has Join, which opens the call; Lyra then records once the meeting app takes the mic.
struct UpcomingSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var calendar = CalendarModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("COMING UP").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
            if calendar.signingIn {
                Banner(text: "Finish signing in to Google in your browser…", spinning: true) { Button("Cancel") { calendar.cancelSignIn() } }
            } else if let problem = calendar.problem {
                Banner(text: problem) { Button(calendar.connected ? "Try again" : "Reconnect") { retry() } }
            }
            if !calendar.connected && !calendar.signingIn {
                connectRow
            } else if calendar.days.isEmpty && calendar.problem == nil && !calendar.signingIn {
                Text("No meetings in the next week.").font(.system(size: 14)).foregroundStyle(.tertiary)
            }
            ForEach(calendar.days, id: \.date) { day in
                VStack(alignment: .leading, spacing: 0) {
                    Text(UpcomingMeetings.label(for: day.date, now: Date()))
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
                    ForEach(day.events) { row($0) }
                }
            }
            .padding(.horizontal, -8)
        }
        .onAppear { calendar.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in calendar.refresh() }
        .task {
            // Drops finished meetings each minute; asks Google again every five.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                calendar.refresh(maxAge: 300)
            }
        }
    }

    private var connectRow: some View {
        Button { calendar.connect() } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                Text("Connect Google Calendar")
                Text("to see the week's meetings here").foregroundStyle(.tertiary)
                Spacer()
            }
            .font(.system(size: 14)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .padding(.horizontal, -8)
    }

    private func row(_ event: CalendarEvent) -> some View {
        let underWay = event.isUnderWay(at: Date())
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
                if event.joinURL != nil { joinPill(prominent: underWay) }
            }
            .font(.system(size: 14))
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .disabled(event.joinURL == nil)
        .help(event.joinURL == nil ? "No call link in this event" : "Join the call — Lyra starts recording once you're let in")
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

    private func retry() { calendar.connected ? calendar.refresh(maxAge: 0) : calendar.connect() }
}
