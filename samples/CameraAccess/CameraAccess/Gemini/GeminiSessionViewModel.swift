import Foundation
import SwiftUI
import UIKit

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
  @Published var lastConferenceExtraction: ConferenceExtraction?
  @Published var activeConferenceContact: ConferenceContact?
  @Published var pendingConferenceConversationSnippet: String?
  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private let eventClient = OpenClawEventClient()
  private let conferenceStore = ConferenceContactStore.shared
  private let conferenceEnrichmentClient = ConferenceEnrichmentClient()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  private var conferenceProcessor = ConferenceExtractionProcessor()
  private var enrichmentTasks: [String: Task<Void, Never>] = [:]
  private var conversationFlushTask: Task<Void, Never>?
  private var resignActiveObserver: NSObjectProtocol?
  private var backgroundObserver: NSObjectProtocol?
  private var foregroundObserver: NSObjectProtocol?
  private var activeConferenceContactID: String?
  private var currentConversationUserText: String = ""
  private var currentConversationAssistantText: String = ""
  private var sessionConferenceModeEnabled: Bool = false
  private var sessionSystemInstruction: String = GeminiConfig.defaultSystemInstruction

  var streamingMode: StreamingMode = .glasses
  var isConferenceModeEnabled: Bool {
    isGeminiActive ? sessionConferenceModeEnabled : SettingsManager.shared.conferenceModeEnabled
  }

  init() {
    observeAppLifecycle()
  }

  deinit {
    if let observer = resignActiveObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = backgroundObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = foregroundObserver {
      NotificationCenter.default.removeObserver(observer)
    }

    conversationFlushTask?.cancel()
    stateObservation?.cancel()
    enrichmentTasks.values.forEach { $0.cancel() }
  }

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open GeminiConfig.swift and replace YOUR_GEMINI_API_KEY with your key from https://aistudio.google.com/apikey"
      return
    }

    isGeminiActive = true
    sessionConferenceModeEnabled = SettingsManager.shared.conferenceModeEnabled
    sessionSystemInstruction = ConferencePrompts.activeSystemInstruction(
      conferenceModeEnabled: sessionConferenceModeEnabled,
      fallbackPrompt: SettingsManager.shared.geminiSystemPrompt
    )
    lastConferenceExtraction = nil
    activeConferenceContact = nil
    pendingConferenceConversationSnippet = nil
    conferenceProcessor = ConferenceExtractionProcessor(config: .current)
    cancelConversationFlushTask()
    activeConferenceContactID = nil
    currentConversationUserText = ""
    currentConversationAssistantText = ""

    // Wire audio callbacks
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        // Mute mic while model speaks when speaker is on the phone
        // (loudspeaker + co-located mic overwhelms iOS echo cancellation)
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        if speakerOnPhone && self.geminiService.isModelSpeaking { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      self?.audioManager.playAudio(data: data)
    }

    geminiService.onInterrupted = { [weak self] in
      self?.audioManager.stopPlayback()
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.flushConferenceConversationIfNeeded()
        // Clear user transcript when AI finishes responding
        self.userTranscript = ""
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript = Self.mergeStreamingTranscript(existing: self.userTranscript, incoming: text)
        self.aiTranscript = ""
        self.captureConferenceInputTranscription(text)
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript = Self.mergeStreamingTranscript(existing: self.aiTranscript, incoming: text)
        self.captureConferenceOutputTranscription(text)
      }
    }

    // Handle unexpected disconnection
    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive else { return }
        self.stopSession()
        self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
      }
    }

    // Check OpenClaw connectivity and start fresh session
    await openClawBridge.checkConnection()
    openClawBridge.resetSession()

    // Wire tool call handling
    toolCallRouter = ToolCallRouter(bridge: openClawBridge)

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          if call.name == ToolDeclarations.extractEntityName {
            let response = self.handleConferenceToolCall(call)
            self.geminiService.sendToolResponse(response)
            continue
          }

          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            self?.geminiService.sendToolResponse(response)
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }

    // Observe service state
    stateObservation = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
        self.toolCallStatus = self.openClawBridge.lastToolCallStatus
        self.openClawConnectionState = self.openClawBridge.connectionState
      }
    }

    // Setup audio
    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isGeminiActive = false
      return
    }

    // Connect to Gemini and wait for setupComplete
    geminiService.configureSession(
      systemInstruction: sessionSystemInstruction,
      conferenceModeEnabled: sessionConferenceModeEnabled
    )
    let setupOk = await geminiService.connect()

    if !setupOk {
      let msg: String
      if case .error(let err) = geminiService.connectionState {
        msg = err
      } else {
        msg = "Failed to connect to Gemini"
      }
      errorMessage = msg
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Start mic capture
    do {
      try audioManager.startCapture()
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Connect to OpenClaw event stream for proactive notifications
    if SettingsManager.shared.proactiveNotificationsEnabled {
      eventClient.onNotification = { [weak self] text in
        guard let self else { return }
        Task { @MainActor in
          guard self.isGeminiActive, self.connectionState == .ready else { return }
          self.geminiService.sendTextMessage(text)
        }
      }
      eventClient.connect()
    }
  }

  func stopSession() {
    eventClient.disconnect()
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    enrichmentTasks.values.forEach { $0.cancel() }
    enrichmentTasks.removeAll()
    cancelConversationFlushTask()
    flushConferenceConversationIfNeeded()
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
    lastConferenceExtraction = nil
    activeConferenceContact = nil
    pendingConferenceConversationSnippet = nil
    activeConferenceContactID = nil
    currentConversationUserText = ""
    currentConversationAssistantText = ""
    sessionConferenceModeEnabled = false
    sessionSystemInstruction = GeminiConfig.defaultSystemInstruction
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  private func handleConferenceToolCall(_ call: GeminiFunctionCall) -> [String: Any] {
    guard isConferenceModeEnabled else {
      return buildLocalToolResponse(
        callId: call.id,
        name: call.name,
        result: .failure("Conference mode is disabled")
      )
    }

    let result = conferenceProcessor.handle(args: call.args)
    switch result {
    case .accepted(let extraction):
      lastConferenceExtraction = extraction
      logConferenceExtraction(extraction, event: "accepted")
      if let contact = conferenceStore.upsert(extraction: extraction) {
        activateConferenceContact(contact)
        scheduleConferenceEnrichmentIfNeeded(for: contact)
      }
      return buildLocalToolResponse(
        callId: call.id,
        name: call.name,
        result: .success("Accepted conference extraction for \(extraction.name)")
      )
    case .review(let extraction):
      lastConferenceExtraction = extraction
      logConferenceExtraction(extraction, event: "review")
      _ = conferenceStore.upsert(extraction: extraction)
      return buildLocalToolResponse(
        callId: call.id,
        name: call.name,
        result: .success("Queued conference extraction for review for \(extraction.name)")
      )
    case .ignoredLowConfidence(let confidence):
      NSLog("[Conference] Ignored low-confidence extraction (%.2f): %@", confidence, String(describing: call.args))
      return buildLocalToolResponse(
        callId: call.id,
        name: call.name,
        result: .success("Ignored low-confidence conference extraction")
      )
    case .ignoredDuplicate:
      NSLog("[Conference] Ignored duplicate extraction: %@", String(describing: call.args))
      return buildLocalToolResponse(
        callId: call.id,
        name: call.name,
        result: .success("Ignored duplicate conference extraction")
      )
    case .invalid(let message):
      NSLog("[Conference] Invalid extraction payload: %@ %@", message, String(describing: call.args))
      return buildLocalToolResponse(
        callId: call.id,
        name: call.name,
        result: .failure(message)
      )
    }
  }

  private func logConferenceExtraction(_ extraction: ConferenceExtraction, event: String) {
    NSLog(
      "[Conference] %@ name=%@ company=%@ role=%@ source=%@ confidence=%.2f observed_text=%@",
      event,
      extraction.name,
      extraction.company ?? "",
      extraction.role ?? "",
      extraction.sourceType.rawValue,
      extraction.confidence,
      extraction.observedText ?? ""
    )
  }

  private func scheduleConferenceEnrichmentIfNeeded(for contact: ConferenceContact) {
    guard GeminiConfig.isOpenClawConfigured else { return }
    guard enrichmentTasks[contact.id] == nil else { return }
    guard conferenceStore.queueEnrichmentIfNeeded(contactID: contact.id) else { return }

    let contactID = contact.id
    let task = Task(priority: .utility) { @MainActor [weak self, conferenceEnrichmentClient, conferenceStore] in
      conferenceStore.markEnrichmentRunning(contactID: contactID)
      let latestContact = conferenceStore.fetchContact(id: contactID) ?? contact
      let result = await conferenceEnrichmentClient.enrich(contact: latestContact)
      switch result {
      case .success(let payload):
        conferenceStore.completeEnrichment(contactID: contactID, payload: payload)
      case .failure(let error):
        conferenceStore.failEnrichment(contactID: contactID, error: error.displayMessage)
      }
      self?.enrichmentTasks.removeValue(forKey: contactID)
    }

    enrichmentTasks[contactID] = task
  }

  private func flushConferenceConversationIfNeeded() {
    cancelConversationFlushTask()

    guard isConferenceModeEnabled else {
      clearConversationBuffer()
      return
    }

    guard let contactID = activeConferenceContactID else {
      clearConversationBuffer()
      return
    }

    let mergedSnippet = Self.buildConversationSnippet(
      userText: currentConversationUserText,
      assistantText: currentConversationAssistantText
    )

    currentConversationUserText = ""
    currentConversationAssistantText = ""
    refreshPendingConferenceConversationSnippet()

    guard let mergedSnippet else { return }
    conferenceStore.appendConversationSnippet(contactID: contactID, snippet: mergedSnippet)
    activeConferenceContact = conferenceStore.fetchContact(id: contactID) ?? activeConferenceContact
  }

  private func activateConferenceContact(_ contact: ConferenceContact) {
    if activeConferenceContactID != nil, activeConferenceContactID != contact.id {
      flushConferenceConversationIfNeeded()
    }
    activeConferenceContactID = contact.id
    activeConferenceContact = contact
    scheduleConversationFlushIfNeeded()
  }

  private func scheduleConversationFlushIfNeeded() {
    cancelConversationFlushTask()

    guard isTrackingConferenceConversation else { return }
    let hasConversationText = !currentConversationUserText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
      !currentConversationAssistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasConversationText else { return }

    // Flush buffered transcript after a short quiet period so conference chats persist
    // even when Gemini doesn't produce a clean turnComplete boundary.
    conversationFlushTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.conversationIdleFlushDelayNanoseconds)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.flushConferenceConversationIfNeeded()
      }
    }
  }

  private func cancelConversationFlushTask() {
    conversationFlushTask?.cancel()
    conversationFlushTask = nil
  }

  private func captureConferenceInputTranscription(_ text: String) {
    guard isTrackingConferenceConversation else {
      clearConversationBuffer()
      return
    }

    currentConversationUserText = Self.mergeStreamingTranscript(
      existing: currentConversationUserText,
      incoming: text
    )
    refreshPendingConferenceConversationSnippet()
    scheduleConversationFlushIfNeeded()
  }

  private func captureConferenceOutputTranscription(_ text: String) {
    guard isTrackingConferenceConversation else {
      clearConversationBuffer()
      return
    }

    currentConversationAssistantText = Self.mergeStreamingTranscript(
      existing: currentConversationAssistantText,
      incoming: text
    )
    refreshPendingConferenceConversationSnippet()
    scheduleConversationFlushIfNeeded()
  }

  private func clearConversationBuffer() {
    cancelConversationFlushTask()
    currentConversationUserText = ""
    currentConversationAssistantText = ""
    pendingConferenceConversationSnippet = nil
  }

  private func observeAppLifecycle() {
    removeAppLifecycleObservers()

    resignActiveObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.handleAppWillResignActive()
      }
    }

    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.handleAppDidEnterBackground()
      }
    }

    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.handleAppWillEnterForeground()
      }
    }
  }

  private func removeAppLifecycleObservers() {
    if let observer = resignActiveObserver {
      NotificationCenter.default.removeObserver(observer)
      resignActiveObserver = nil
    }
    if let observer = backgroundObserver {
      NotificationCenter.default.removeObserver(observer)
      backgroundObserver = nil
    }
    if let observer = foregroundObserver {
      NotificationCenter.default.removeObserver(observer)
      foregroundObserver = nil
    }
  }

  private func handleAppWillResignActive() {
    guard isGeminiActive else { return }
    flushConferenceConversationIfNeeded()
  }

  private func handleAppDidEnterBackground() {
    guard isGeminiActive else { return }
    flushConferenceConversationIfNeeded()
  }

  private func handleAppWillEnterForeground() {
    guard isGeminiActive, let contactID = activeConferenceContactID else { return }
    activeConferenceContact = conferenceStore.fetchContact(id: contactID) ?? activeConferenceContact
    refreshPendingConferenceConversationSnippet()
  }

  private func refreshPendingConferenceConversationSnippet() {
    pendingConferenceConversationSnippet = Self.buildConversationSnippet(
      userText: currentConversationUserText,
      assistantText: currentConversationAssistantText
    )
  }

  private func buildLocalToolResponse(
    callId: String,
    name: String,
    result: ToolResult
  ) -> [String: Any] {
    [
      "toolResponse": [
        "functionResponses": [
          [
            "id": callId,
            "name": name,
            "response": result.responseValue
          ]
        ]
      ]
    ]
  }

  private static let conversationIdleFlushDelayNanoseconds: UInt64 = 6_000_000_000

  private var isTrackingConferenceConversation: Bool {
    isConferenceModeEnabled && activeConferenceContactID != nil
  }

  static func mergeStreamingTranscript(existing: String, incoming: String) -> String {
    let cleanedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !cleanedIncoming.isEmpty else { return cleanedExisting }
    guard !cleanedExisting.isEmpty else { return cleanedIncoming }

    if cleanedIncoming == cleanedExisting {
      return cleanedExisting
    }

    if cleanedIncoming.hasPrefix(cleanedExisting) {
      return cleanedIncoming
    }

    if cleanedExisting.hasPrefix(cleanedIncoming) {
      return cleanedExisting
    }

    let overlapLength = overlapLength(between: cleanedExisting, and: cleanedIncoming)
    if overlapLength > 0 {
      let overlapSuffix = String(cleanedIncoming.dropFirst(overlapLength))
      return (cleanedExisting + overlapSuffix).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return joinTranscriptSegments(existing: cleanedExisting, incoming: cleanedIncoming)
  }

  static func buildConversationSnippet(userText: String, assistantText: String) -> String? {
    let userSnippet = userText.trimmingCharacters(in: .whitespacesAndNewlines)
    let assistantSnippet = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)

    var transcriptParts: [String] = []
    if !userSnippet.isEmpty {
      transcriptParts.append("User: \(userSnippet)")
    }
    if !assistantSnippet.isEmpty {
      transcriptParts.append("Assistant: \(assistantSnippet)")
    }

    let mergedSnippet = transcriptParts.joined(separator: "\n")
    return mergedSnippet.isEmpty ? nil : mergedSnippet
  }

  private static func overlapLength(between existing: String, and incoming: String) -> Int {
    let maxOverlap = min(existing.count, incoming.count)
    guard maxOverlap > 0 else { return 0 }

    for length in stride(from: maxOverlap, through: 1, by: -1) {
      if String(existing.suffix(length)) == String(incoming.prefix(length)) {
        return length
      }
    }

    return 0
  }

  private static func joinTranscriptSegments(existing: String, incoming: String) -> String {
    guard let firstIncomingCharacter = incoming.first else { return existing }
    let needsSeparator = !(existing.last?.isWhitespace ?? false) &&
      !firstIncomingCharacter.isWhitespace &&
      !",.!?;:".contains(firstIncomingCharacter)

    if needsSeparator {
      return "\(existing) \(incoming)"
    }

    return existing + incoming
  }
}
