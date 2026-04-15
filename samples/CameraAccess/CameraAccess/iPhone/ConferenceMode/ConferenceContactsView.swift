import SwiftUI

struct ConferenceContactsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var contacts: [ConferenceContact] = []
  @State private var retryingContactIDs: Set<String> = []
  private let store = ConferenceContactStore.shared
  private let enrichmentClient = ConferenceEnrichmentClient()

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
            ConferenceContactRow(
              contact: contact,
              isRetrying: retryingContactIDs.contains(contact.id),
              onRetry: {
                retry(contact)
              }
            )
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
    .task {
      while !Task.isCancelled {
        reload()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
  }

  private func reload() {
    contacts = store.fetchContacts()
  }

  private func retry(_ contact: ConferenceContact) {
    guard !retryingContactIDs.contains(contact.id) else { return }

    retryingContactIDs.insert(contact.id)
    Task {
      defer {
        Task { @MainActor in
          retryingContactIDs.remove(contact.id)
          reload()
        }
      }

      guard store.queueEnrichmentIfNeeded(contactID: contact.id) else { return }

      store.markEnrichmentRunning(contactID: contact.id)
      let latestContact = store.fetchContact(id: contact.id) ?? contact
      let result = await enrichmentClient.enrich(contact: latestContact)
      switch result {
      case .success(let payload):
        store.completeEnrichment(contactID: contact.id, payload: payload)
      case .failure(let message):
        store.failEnrichment(contactID: contact.id, error: message)
      }
    }
  }
}

private struct ConferenceContactRow: View {
  let contact: ConferenceContact
  let isRetrying: Bool
  let onRetry: () -> Void

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

      if let conversationSnippet = contact.conversationSnippet, !conversationSnippet.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Conversation")
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
          Text(conversationSnippet)
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      if contact.canRetryEnrichment {
        HStack {
          Spacer()
          Button(isRetrying ? "Retrying..." : "Retry Enrichment") {
            onRetry()
          }
          .font(.caption.weight(.semibold))
          .disabled(isRetrying)
        }
      }
    }
    .padding(.vertical, 6)
  }
}
