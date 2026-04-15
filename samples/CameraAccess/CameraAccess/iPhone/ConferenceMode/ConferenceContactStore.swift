import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ConferenceContactStore {
  static let shared = ConferenceContactStore()

  private let queue = DispatchQueue(label: "conference-contact-store")
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let databaseURL: URL
  private var db: OpaquePointer?

  init(databaseURL: URL? = nil) {
    if let databaseURL {
      self.databaseURL = databaseURL
    } else {
      let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
      let directoryURL = baseURL.appendingPathComponent("ConferenceMode", isDirectory: true)
      try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      self.databaseURL = directoryURL.appendingPathComponent("conference-contacts.sqlite")
    }

    queue.sync {
      openDatabaseIfNeeded()
      createTablesIfNeeded()
    }
  }

  func fetchContacts(limit: Int = 100) -> [ConferenceContact] {
    queue.sync {
      openDatabaseIfNeeded()
      guard let db else { return [] }

      let sql = """
      SELECT id, dedupe_key, name, company, role, source_type, confidence, observed_text,
             disposition, first_seen_at, last_seen_at, enrichment_status, enrichment_json,
             enrichment_error, last_enriched_at, conversation_snippet, last_conversation_at
      FROM conference_contacts
      ORDER BY COALESCE(last_conversation_at, last_seen_at) DESC, last_seen_at DESC
      LIMIT ?;
      """

      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
      defer { sqlite3_finalize(statement) }

      sqlite3_bind_int(statement, 1, Int32(limit))

      var results: [ConferenceContact] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        if let contact = readContact(from: statement) {
          results.append(contact)
        }
      }
      return results
    }
  }

  func fetchContact(id: String) -> ConferenceContact? {
    queue.sync {
      openDatabaseIfNeeded()
      guard let db else { return nil }

      let sql = """
      SELECT id, dedupe_key, name, company, role, source_type, confidence, observed_text,
             disposition, first_seen_at, last_seen_at, enrichment_status, enrichment_json,
             enrichment_error, last_enriched_at, conversation_snippet, last_conversation_at
      FROM conference_contacts
      WHERE id = ?
      LIMIT 1;
      """

      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
      defer { sqlite3_finalize(statement) }

      sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return readContact(from: statement)
    }
  }

  @discardableResult
  func upsert(extraction: ConferenceExtraction) -> ConferenceContact? {
    queue.sync {
      openDatabaseIfNeeded()
      guard let db else { return nil }

      let dedupeKey = ConferenceExtractionProcessor.normalizedKey(
        name: extraction.name,
        company: extraction.company,
        sourceType: extraction.sourceType
      )

      if let existing = fetchByDedupeKey(dedupeKey, db: db) {
        let merged = ConferenceContact(
          id: existing.id,
          dedupeKey: dedupeKey,
          name: existing.name,
          company: extraction.company ?? existing.company,
          role: extraction.role ?? existing.role,
          sourceType: extraction.sourceType,
          confidence: max(existing.confidence, extraction.confidence),
          observedText: extraction.observedText ?? existing.observedText,
          disposition: existing.disposition == .accepted || extraction.disposition == .accepted ? .accepted : .review,
          firstSeenAt: existing.firstSeenAt,
          lastSeenAt: extraction.detectedAt,
          enrichmentStatus: existing.enrichmentStatus,
          enrichment: existing.enrichment,
          enrichmentError: existing.enrichmentError,
          lastEnrichedAt: existing.lastEnrichedAt,
          conversationSnippet: existing.conversationSnippet,
          lastConversationAt: existing.lastConversationAt
        )

        save(contact: merged, db: db)
        return merged
      }

      let contact = ConferenceContact(
        id: UUID().uuidString,
        dedupeKey: dedupeKey,
        name: extraction.name,
        company: extraction.company,
        role: extraction.role,
        sourceType: extraction.sourceType,
        confidence: extraction.confidence,
        observedText: extraction.observedText,
        disposition: extraction.disposition,
        firstSeenAt: extraction.detectedAt,
        lastSeenAt: extraction.detectedAt,
        enrichmentStatus: .notRequested,
        enrichment: nil,
        enrichmentError: nil,
        lastEnrichedAt: nil,
        conversationSnippet: nil,
        lastConversationAt: nil
      )

      save(contact: contact, db: db)
      return contact
    }
  }

  func queueEnrichmentIfNeeded(contactID: String) -> Bool {
    queue.sync {
      openDatabaseIfNeeded()
      guard let db, let contact = fetchByID(contactID, db: db) else { return false }
      guard contact.disposition == .accepted else { return false }
      guard contact.enrichmentStatus == .notRequested || contact.enrichmentStatus == .failed else {
        return false
      }

      let updated = ConferenceContact(
        id: contact.id,
        dedupeKey: contact.dedupeKey,
        name: contact.name,
        company: contact.company,
        role: contact.role,
        sourceType: contact.sourceType,
        confidence: contact.confidence,
        observedText: contact.observedText,
        disposition: contact.disposition,
        firstSeenAt: contact.firstSeenAt,
        lastSeenAt: contact.lastSeenAt,
        enrichmentStatus: .queued,
        enrichment: contact.enrichment,
        enrichmentError: nil,
        lastEnrichedAt: contact.lastEnrichedAt,
        conversationSnippet: contact.conversationSnippet,
        lastConversationAt: contact.lastConversationAt
      )
      save(contact: updated, db: db)
      return true
    }
  }

  func markEnrichmentRunning(contactID: String) {
    updateStatus(contactID: contactID, status: .enriching, error: nil)
  }

  func completeEnrichment(contactID: String, payload: ConferenceEnrichmentPayload, completedAt: Date = Date()) {
    queue.sync {
      openDatabaseIfNeeded()
      guard let db, let contact = fetchByID(contactID, db: db) else { return }

      let updated = ConferenceContact(
        id: contact.id,
        dedupeKey: contact.dedupeKey,
        name: contact.name,
        company: contact.company,
        role: contact.role,
        sourceType: contact.sourceType,
        confidence: contact.confidence,
        observedText: contact.observedText,
        disposition: contact.disposition,
        firstSeenAt: contact.firstSeenAt,
        lastSeenAt: contact.lastSeenAt,
        enrichmentStatus: .completed,
        enrichment: payload,
        enrichmentError: nil,
        lastEnrichedAt: completedAt,
        conversationSnippet: contact.conversationSnippet,
        lastConversationAt: contact.lastConversationAt
      )
      save(contact: updated, db: db)
    }
  }

  func failEnrichment(contactID: String, error: String) {
    updateStatus(contactID: contactID, status: .failed, error: error)
  }

  func appendConversationSnippet(contactID: String, snippet: String, observedAt: Date = Date()) {
    let cleanedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanedSnippet.isEmpty else { return }

    queue.sync {
      openDatabaseIfNeeded()
      guard let db, let contact = fetchByID(contactID, db: db) else { return }

      let updated = ConferenceContact(
        id: contact.id,
        dedupeKey: contact.dedupeKey,
        name: contact.name,
        company: contact.company,
        role: contact.role,
        sourceType: contact.sourceType,
        confidence: contact.confidence,
        observedText: contact.observedText,
        disposition: contact.disposition,
        firstSeenAt: contact.firstSeenAt,
        lastSeenAt: contact.lastSeenAt,
        enrichmentStatus: contact.enrichmentStatus,
        enrichment: contact.enrichment,
        enrichmentError: contact.enrichmentError,
        lastEnrichedAt: contact.lastEnrichedAt,
        conversationSnippet: Self.mergeConversationSnippet(
          existing: contact.conversationSnippet,
          newSnippet: cleanedSnippet
        ),
        lastConversationAt: observedAt
      )
      save(contact: updated, db: db)
    }
  }

  // MARK: - Private

  private func updateStatus(contactID: String, status: ConferenceEnrichmentStatus, error: String?) {
    queue.sync {
      openDatabaseIfNeeded()
      guard let db, let contact = fetchByID(contactID, db: db) else { return }

      let updated = ConferenceContact(
        id: contact.id,
        dedupeKey: contact.dedupeKey,
        name: contact.name,
        company: contact.company,
        role: contact.role,
        sourceType: contact.sourceType,
        confidence: contact.confidence,
        observedText: contact.observedText,
        disposition: contact.disposition,
        firstSeenAt: contact.firstSeenAt,
        lastSeenAt: contact.lastSeenAt,
        enrichmentStatus: status,
        enrichment: contact.enrichment,
        enrichmentError: error,
        lastEnrichedAt: contact.lastEnrichedAt,
        conversationSnippet: contact.conversationSnippet,
        lastConversationAt: contact.lastConversationAt
      )
      save(contact: updated, db: db)
    }
  }

  private func openDatabaseIfNeeded() {
    guard db == nil else { return }
    guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
      db = nil
      return
    }
  }

  private func createTablesIfNeeded() {
    guard let db else { return }
    let sql = """
    CREATE TABLE IF NOT EXISTS conference_contacts (
      id TEXT PRIMARY KEY NOT NULL,
      dedupe_key TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      company TEXT,
      role TEXT,
      source_type TEXT NOT NULL,
      confidence REAL NOT NULL,
      observed_text TEXT,
      disposition TEXT NOT NULL,
      first_seen_at REAL NOT NULL,
      last_seen_at REAL NOT NULL,
      enrichment_status TEXT NOT NULL,
      enrichment_json TEXT,
      enrichment_error TEXT,
      last_enriched_at REAL,
      conversation_snippet TEXT,
      last_conversation_at REAL
    );
    """
    sqlite3_exec(db, sql, nil, nil, nil)
    sqlite3_exec(db, "ALTER TABLE conference_contacts ADD COLUMN conversation_snippet TEXT;", nil, nil, nil)
    sqlite3_exec(db, "ALTER TABLE conference_contacts ADD COLUMN last_conversation_at REAL;", nil, nil, nil)
  }

  private func fetchByDedupeKey(_ dedupeKey: String, db: OpaquePointer) -> ConferenceContact? {
    let sql = """
    SELECT id, dedupe_key, name, company, role, source_type, confidence, observed_text,
           disposition, first_seen_at, last_seen_at, enrichment_status, enrichment_json,
           enrichment_error, last_enriched_at, conversation_snippet, last_conversation_at
    FROM conference_contacts
    WHERE dedupe_key = ?
    LIMIT 1;
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, dedupeKey, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return readContact(from: statement)
  }

  private func fetchByID(_ id: String, db: OpaquePointer) -> ConferenceContact? {
    let sql = """
    SELECT id, dedupe_key, name, company, role, source_type, confidence, observed_text,
           disposition, first_seen_at, last_seen_at, enrichment_status, enrichment_json,
           enrichment_error, last_enriched_at, conversation_snippet, last_conversation_at
    FROM conference_contacts
    WHERE id = ?
    LIMIT 1;
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return readContact(from: statement)
  }

  private func save(contact: ConferenceContact, db: OpaquePointer) {
    let sql = """
    INSERT OR REPLACE INTO conference_contacts (
      id, dedupe_key, name, company, role, source_type, confidence, observed_text,
      disposition, first_seen_at, last_seen_at, enrichment_status, enrichment_json,
      enrichment_error, last_enriched_at, conversation_snippet, last_conversation_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(statement) }

    let enrichmentJSON = contact.enrichment.flatMap { try? encoder.encode($0) }.flatMap {
      String(data: $0, encoding: .utf8)
    }

    bind(text: contact.id, index: 1, statement: statement)
    bind(text: contact.dedupeKey, index: 2, statement: statement)
    bind(text: contact.name, index: 3, statement: statement)
    bind(text: contact.company, index: 4, statement: statement)
    bind(text: contact.role, index: 5, statement: statement)
    bind(text: contact.sourceType.rawValue, index: 6, statement: statement)
    sqlite3_bind_double(statement, 7, contact.confidence)
    bind(text: contact.observedText, index: 8, statement: statement)
    bind(text: contact.disposition.rawValue, index: 9, statement: statement)
    sqlite3_bind_double(statement, 10, contact.firstSeenAt.timeIntervalSince1970)
    sqlite3_bind_double(statement, 11, contact.lastSeenAt.timeIntervalSince1970)
    bind(text: contact.enrichmentStatus.rawValue, index: 12, statement: statement)
    bind(text: enrichmentJSON, index: 13, statement: statement)
    bind(text: contact.enrichmentError, index: 14, statement: statement)
    if let lastEnrichedAt = contact.lastEnrichedAt {
      sqlite3_bind_double(statement, 15, lastEnrichedAt.timeIntervalSince1970)
    } else {
      sqlite3_bind_null(statement, 15)
    }
    bind(text: contact.conversationSnippet, index: 16, statement: statement)
    if let lastConversationAt = contact.lastConversationAt {
      sqlite3_bind_double(statement, 17, lastConversationAt.timeIntervalSince1970)
    } else {
      sqlite3_bind_null(statement, 17)
    }

    sqlite3_step(statement)
  }

  private func readContact(from statement: OpaquePointer?) -> ConferenceContact? {
    guard let statement,
          let id = readString(statement, index: 0),
          let dedupeKey = readString(statement, index: 1),
          let name = readString(statement, index: 2),
          let sourceRaw = readString(statement, index: 5),
          let sourceType = ConferenceSourceType(rawValue: sourceRaw),
          let dispositionRaw = readString(statement, index: 8),
          let disposition = ConferenceExtractionDisposition(rawValue: dispositionRaw),
          let enrichmentStatusRaw = readString(statement, index: 11),
          let enrichmentStatus = ConferenceEnrichmentStatus(rawValue: enrichmentStatusRaw)
    else {
      return nil
    }

    let enrichment: ConferenceEnrichmentPayload?
    if let enrichmentJSON = readString(statement, index: 12),
       let data = enrichmentJSON.data(using: .utf8) {
      enrichment = try? decoder.decode(ConferenceEnrichmentPayload.self, from: data)
    } else {
      enrichment = nil
    }

    let lastEnrichedAt: Date?
    if sqlite3_column_type(statement, 14) == SQLITE_NULL {
      lastEnrichedAt = nil
    } else {
      lastEnrichedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 14))
    }

    let lastConversationAt: Date?
    if sqlite3_column_type(statement, 16) == SQLITE_NULL {
      lastConversationAt = nil
    } else {
      lastConversationAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 16))
    }

    return ConferenceContact(
      id: id,
      dedupeKey: dedupeKey,
      name: name,
      company: readString(statement, index: 3),
      role: readString(statement, index: 4),
      sourceType: sourceType,
      confidence: sqlite3_column_double(statement, 6),
      observedText: readString(statement, index: 7),
      disposition: disposition,
      firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
      lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
      enrichmentStatus: enrichmentStatus,
      enrichment: enrichment,
      enrichmentError: readString(statement, index: 13),
      lastEnrichedAt: lastEnrichedAt,
      conversationSnippet: readString(statement, index: 15),
      lastConversationAt: lastConversationAt
    )
  }

  static func mergeConversationSnippet(existing: String?, newSnippet: String, maxCharacters: Int = 1200) -> String {
    let cleanedNewSnippet = newSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanedNewSnippet.isEmpty else {
      return existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    let cleanedExisting = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let merged: String
    if cleanedExisting.isEmpty {
      merged = cleanedNewSnippet
    } else if cleanedExisting.contains(cleanedNewSnippet) {
      merged = cleanedExisting
    } else {
      merged = "\(cleanedExisting)\n\n\(cleanedNewSnippet)"
    }

    if merged.count <= maxCharacters {
      return merged
    }

    let index = merged.index(merged.endIndex, offsetBy: -maxCharacters)
    return String(merged[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func bind(text: String?, index: Int32, statement: OpaquePointer?) {
    guard let text else {
      sqlite3_bind_null(statement, index)
      return
    }
    sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
  }

  private func readString(_ statement: OpaquePointer?, index: Int32) -> String? {
    guard let text = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: text)
  }
}
