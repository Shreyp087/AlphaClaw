import Foundation
import XCTest

@testable import CameraAccess

final class ConferenceModeTests: XCTestCase {
  private var temporaryDatabaseURLs: [URL] = []

  override func tearDown() {
    SettingsManager.shared.resetAll()
    temporaryDatabaseURLs.forEach { try? FileManager.default.removeItem(at: $0) }
    temporaryDatabaseURLs.removeAll()
    super.tearDown()
  }

  func testConferencePromptUsesFallbackWhenDisabled() {
    let fallback = "custom prompt"

    XCTAssertEqual(
      ConferencePrompts.activeSystemInstruction(conferenceModeEnabled: false, fallbackPrompt: fallback),
      fallback
    )
  }

  func testConferencePromptUsesRelationshipOpsWhenEnabled() {
    XCTAssertEqual(
      ConferencePrompts.activeSystemInstruction(conferenceModeEnabled: true, fallbackPrompt: "custom"),
      ConferencePrompts.relationshipOps
    )
  }

  func testToolDeclarationsExcludeExtractEntityWhenConferenceModeDisabled() {
    let names = ToolDeclarations.allDeclarations(conferenceModeEnabled: false).compactMap {
      $0["name"] as? String
    }

    XCTAssertEqual(names, [ToolDeclarations.executeName])
  }

  func testToolDeclarationsIncludeExtractEntityWhenConferenceModeEnabled() {
    let names = ToolDeclarations.allDeclarations(conferenceModeEnabled: true).compactMap {
      $0["name"] as? String
    }

    XCTAssertEqual(names, [ToolDeclarations.executeName, ToolDeclarations.extractEntityName])
  }

  func testProcessorAcceptsHighConfidenceExtraction() {
    var processor = makeProcessor()

    let result = processor.handle(
      args: [
        "name": "Sarah Chen",
        "company": "Acme AI",
        "role": "VP Engineering",
        "source_type": "badge",
        "confidence": 0.92
      ],
      now: Date(timeIntervalSince1970: 0)
    )

    guard case .accepted(let extraction) = result else {
      return XCTFail("Expected accepted extraction, got \(result)")
    }

    XCTAssertEqual(extraction.name, "Sarah Chen")
    XCTAssertEqual(extraction.company, "Acme AI")
    XCTAssertEqual(extraction.sourceType, .badge)
    XCTAssertEqual(extraction.disposition, .accepted)
  }

  func testProcessorReturnsReviewForMidConfidenceExtraction() {
    var processor = makeProcessor()

    let result = processor.handle(
      args: [
        "name": "Taylor Reed",
        "source_type": "card",
        "confidence": 0.61
      ],
      now: Date(timeIntervalSince1970: 0)
    )

    guard case .review(let extraction) = result else {
      return XCTFail("Expected review extraction, got \(result)")
    }

    XCTAssertEqual(extraction.disposition, .review)
    XCTAssertEqual(extraction.sourceType, .card)
  }

  func testProcessorIgnoresLowConfidenceExtraction() {
    var processor = makeProcessor()

    let result = processor.handle(
      args: [
        "name": "Jamie Park",
        "source_type": "booth",
        "confidence": 0.32
      ],
      now: Date(timeIntervalSince1970: 0)
    )

    guard case .ignoredLowConfidence(let confidence) = result else {
      return XCTFail("Expected low-confidence ignore, got \(result)")
    }

    XCTAssertEqual(confidence, 0.32, accuracy: 0.0001)
  }

  func testProcessorSuppressesDuplicatesWithinCooldown() {
    var processor = makeProcessor()

    let firstResult = processor.handle(
      args: [
        "name": "Morgan Lee",
        "company": "OpenClaw",
        "source_type": "badge",
        "confidence": 0.88
      ],
      now: Date(timeIntervalSince1970: 0)
    )

    guard case .accepted = firstResult else {
      return XCTFail("Expected first extraction to be accepted, got \(firstResult)")
    }

    let secondResult = processor.handle(
      args: [
        "name": "Morgan Lee",
        "company": "OpenClaw",
        "source_type": "badge",
        "confidence": 0.91
      ],
      now: Date(timeIntervalSince1970: 5)
    )

    XCTAssertEqual(secondResult, .ignoredDuplicate)
  }

  func testConferenceContactStoreInsertsExtraction() {
    let store = makeStore()
    let extraction = ConferenceExtraction(
      name: "Priya Shah",
      company: "Northstar Labs",
      role: "Founder",
      sourceType: .badge,
      confidence: 0.9,
      observedText: "Priya Shah | Northstar Labs",
      disposition: .accepted,
      detectedAt: Date(timeIntervalSince1970: 10)
    )

    let stored = store.upsert(extraction: extraction)

    XCTAssertEqual(stored?.name, "Priya Shah")
    XCTAssertEqual(store.fetchContacts().count, 1)
    XCTAssertEqual(store.fetchContacts().first?.enrichmentStatus, .notRequested)
  }

  func testConferenceContactStoreMergesDuplicateExtraction() {
    let store = makeStore()

    _ = store.upsert(extraction: ConferenceExtraction(
      name: "Jordan Kim",
      company: "Beacon",
      role: nil,
      sourceType: .badge,
      confidence: 0.62,
      observedText: nil,
      disposition: .review,
      detectedAt: Date(timeIntervalSince1970: 10)
    ))

    let updated = store.upsert(extraction: ConferenceExtraction(
      name: "Jordan Kim",
      company: "Beacon",
      role: "CEO",
      sourceType: .badge,
      confidence: 0.91,
      observedText: "Jordan Kim CEO Beacon",
      disposition: .accepted,
      detectedAt: Date(timeIntervalSince1970: 20)
    ))

    XCTAssertEqual(store.fetchContacts().count, 1)
    XCTAssertEqual(updated?.role, "CEO")
    XCTAssertEqual(updated?.disposition, .accepted)
    XCTAssertEqual(updated?.confidence, 0.91, accuracy: 0.0001)
  }

  func testConferenceEnrichmentPayloadParserExtractsJSON() {
    let response = """
    Here is the result:
    {"headline":"AI founder building wearable copilots","company_summary":"Northstar Labs builds AI workflow tools.","talking_points":["Ask about conference demos","Mention wearable UX","Follow up on distribution"],"follow_up":"Send a product intro after the event.","confidence_notes":"Role is explicit; company scope inferred from public copy.","source_urls":["https://northstar.example.com"]}
    """

    let payload = ConferenceEnrichmentClient.parsePayload(from: response)

    XCTAssertEqual(payload.headline, "AI founder building wearable copilots")
    XCTAssertEqual(payload.talkingPoints.count, 3)
    XCTAssertEqual(payload.sourceURLs.count, 1)
  }

  private func makeProcessor() -> ConferenceExtractionProcessor {
    ConferenceExtractionProcessor(
      config: ConferenceModeConfig(
        enabled: true,
        acceptedConfidenceMin: 0.70,
        reviewConfidenceMin: 0.50,
        duplicateCooldown: 10
      )
    )
  }

  private func makeStore() -> ConferenceContactStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sqlite")
    temporaryDatabaseURLs.append(url)
    return ConferenceContactStore(databaseURL: url)
  }
}
