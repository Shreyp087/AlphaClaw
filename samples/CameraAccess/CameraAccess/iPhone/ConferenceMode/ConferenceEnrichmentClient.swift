import Foundation

enum ConferenceEnrichmentError: LocalizedError, Equatable, Sendable {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let message):
      return message
    }
  }

  var displayMessage: String {
    errorDescription ?? "Unknown conference enrichment error"
  }
}

struct ConferenceEnrichmentClient: Sendable {
  private let session: URLSession
  private let sessionKey = "agent:conference:networking"

  init(session: URLSession = .shared) {
    self.session = session
  }

  func enrich(contact: ConferenceContact) async -> Result<ConferenceEnrichmentPayload, ConferenceEnrichmentError> {
    guard GeminiConfig.isOpenClawConfigured else {
      return .failure(.message("OpenClaw is not configured"))
    }

    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
      return .failure(.message("Invalid OpenClaw gateway URL"))
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": [
        [
          "role": "user",
          "content": Self.buildTask(for: contact)
        ]
      ],
      "stream": false
    ]

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode) else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return .failure(.message("OpenClaw returned HTTP \(code)"))
      }

      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String else {
        return .failure(.message("OpenClaw returned an unexpected response shape"))
      }

      return .success(Self.parsePayload(from: content))
    } catch {
      return .failure(.message(error.localizedDescription))
    }
  }

  static func buildTask(for contact: ConferenceContact) -> String {
    """
    You are networking_autopilot, a relationship research assistant helping a conference attendee.

    Research the detected person or organization using any tools available to you and return ONLY a JSON object with this exact shape:
    {
      "headline": "short one-line summary",
      "company_summary": "what their company appears to do",
      "talking_points": ["bullet one", "bullet two", "bullet three"],
      "follow_up": "best follow-up angle or next step",
      "confidence_notes": "what is solid vs inferred",
      "source_urls": ["https://example.com"]
    }

    Rules:
    - Return valid JSON only. No markdown fences.
    - Use an empty string for unknown string fields.
    - Use an empty array for unknown list fields.
    - Be conservative when inferring details.

    Detected contact:
    - name: \(contact.name)
    - company: \(contact.company ?? "")
    - role: \(contact.role ?? "")
    - source_type: \(contact.sourceType.rawValue)
    - confidence: \(String(format: "%.2f", contact.confidence))
    - observed_text: \(contact.observedText ?? "")
    """
  }

  static func parsePayload(from response: String) -> ConferenceEnrichmentPayload {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    let jsonText = extractJSONObjectText(from: trimmed) ?? trimmed

    if let data = jsonText.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      return ConferenceEnrichmentPayload(
        headline: sanitize(object["headline"]),
        companySummary: sanitize(object["company_summary"]),
        talkingPoints: sanitizeArray(object["talking_points"]),
        followUp: sanitize(object["follow_up"]),
        confidenceNotes: sanitize(object["confidence_notes"]),
        sourceURLs: sanitizeArray(object["source_urls"]),
        rawResponse: trimmed
      )
    }

    return ConferenceEnrichmentPayload(
      headline: nil,
      companySummary: nil,
      talkingPoints: [],
      followUp: nil,
      confidenceNotes: nil,
      sourceURLs: [],
      rawResponse: trimmed
    )
  }

  private static func extractJSONObjectText(from text: String) -> String? {
    guard let start = text.firstIndex(of: "{"),
          let end = text.lastIndex(of: "}") else {
      return nil
    }
    return String(text[start...end])
  }

  private static func sanitize(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func sanitizeArray(_ value: Any?) -> [String] {
    guard let array = value as? [Any] else { return [] }
    return array.compactMap { item in
      guard let string = item as? String else { return nil }
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }
}
