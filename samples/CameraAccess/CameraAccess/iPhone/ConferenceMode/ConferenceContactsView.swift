import SwiftUI

struct ConferenceContactsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var contacts: [ConferenceContact] = []

  var body: some View {
    NavigationView {
      Group {
        if contacts.isEmpty {
          ContentUnavailableView(
            "No Conference Contacts Yet",
            systemImage: "person.crop.rectangle.stack",
            description: Text("Accepted and review-band detections will appear here once conference mode captures them.")
          )
        } else {
          List(contacts) { contact in
            ConferenceContactRow(contact: contact)
          }
          .listStyle(.plain)
        }
      }
      .navigationTitle("Conference Contacts")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Close") {
            dismiss()
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Refresh") {
            reload()
          }
        }
      }
    }
    .onAppear {
      reload()
    }
  }

  private func reload() {
    contacts = ConferenceContactStore.shared.fetchContacts()
  }
}

private struct ConferenceContactRow: View {
  let contact: ConferenceContact

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(contact.name)
            .font(.headline)
          if !contact.summaryText.isEmpty {
            Text(contact.summaryText)
              .font(.subheadline)
              .foregroundColor(.secondary)
          }
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 4) {
          Text(contact.disposition.displayName)
            .font(.caption.weight(.semibold))
            .foregroundColor(contact.disposition == .accepted ? .green : .orange)
          Text(contact.enrichmentStatus.displayName)
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Text("\(contact.sourceType.displayName) | \(Int((contact.confidence * 100).rounded()))% confidence")
        .font(.caption)
        .foregroundColor(.secondary)

      if let summary = contact.enrichment?.summaryText, !summary.isEmpty {
        Text(summary)
          .font(.body)
      } else if let rawResponse = contact.enrichment?.rawResponse, !rawResponse.isEmpty {
        Text(rawResponse)
          .font(.body)
      } else if let error = contact.enrichmentError, !error.isEmpty {
        Text(error)
          .font(.caption)
          .foregroundColor(.red)
      }

      if let talkingPoints = contact.enrichment?.talkingPoints, !talkingPoints.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(talkingPoints, id: \.self) { point in
            Text("- \(point)")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
      }
    }
    .padding(.vertical, 6)
  }
}
