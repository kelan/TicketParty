import SwiftUI

struct ActivityView: View {
    private var events: [StubActivityEvent] {
        PreviewRuntime.usesStubData ? SampleData.activityEvents : []
    }

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "clock.arrow.circlepath")
            } else {
                List(events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title)
                            .font(.headline)
                        Text(event.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(event.timestamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Activity")
    }
}
