import Foundation

enum ConferenceEnrichmentStatus: String, CaseIterable, Codable, Equatable {
  case notRequested
  case queued
  case enriching
  case completed
  case failed

  var displayName: String {
    switch self {
    case .notRequested: return "Not Requested"
    case .queued: return "Queued"
    case .enriching: return "Enriching"
    case .completed: return "Enriched"
    case .failed: return "Needs Retry"
    }
  }
}

struct ConferenceEnrichmentPayload: Codable, Equatable {
  let headline: String?
  let companySummary: String?
  let talkingPoints: [String]
  let followUp: String?
  let confidenceNotes: String?
  let sourceURLs: [String]
  let rawResponse: String?

  var summaryText: String {
    [headline, companySummary, followUp]
      .compactMap { value in
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
      }
      .joined(separator: "\n\n")
  }
}

struct ConferenceContact: Identifiable, Equatable {
  let id: String
  let dedupeKey: String
  let name: String
  let company: String?
  let role: String?
  let sourceType: ConferenceSourceType
  let confidence: Double
  let observedText: String?
  let disposition: ConferenceExtractionDisposition
  let firstSeenAt: Date
  let lastSeenAt: Date
  let enrichmentStatus: ConferenceEnrichmentStatus
  let enrichment: ConferenceEnrichmentPayload?
  let enrichmentError: String?
  let lastEnrichedAt: Date?

  var summaryText: String {
    [company, role]
      .compactMap { value in
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
      }
      .joined(separator: " / ")
  }
}
