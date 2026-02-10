import SwiftUI

struct ActivityView: View {
    var body: some View {
        List(SampleData.activityEvents) { event in
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
        .navigationTitle("Activity")
    }
}
