import Foundation
import SwiftData
import TicketPartyModels

public struct TicketConversationThreadRecord: Sendable, Hashable {
    public let id: UUID
    public let ticketID: UUID
    public let mode: TicketConversationMode
    public let rollingSummary: String
    public let lastCompactedSequence: Int64
    public let createdAt: Date
    public let updatedAt: Date
}

public struct TicketConversationMessageRecord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let threadID: UUID
    public let ticketID: UUID
    public let sequence: Int64
    public let role: TicketConversationRole
    public let status: TicketConversationMessageStatus
    public let content: String
    public let requiresResponse: Bool
    public let runID: UUID?
    public let createdAt: Date
    public let updatedAt: Date
}

public final class TicketConversationStore {
    public enum StoreError: LocalizedError {
        case threadNotFound(UUID)
        case streamingAssistantMessageNotFound(UUID)

        public var errorDescription: String? {
            switch self {
            case let .threadNotFound(ticketID):
                "Conversation thread not found for ticket \(ticketID.uuidString)"
            case let .streamingAssistantMessageNotFound(ticketID):
                "Streaming assistant message not found for ticket \(ticketID.uuidString)"
            }
        }
    }

    public static let defaultWindowCount = 12
    public static let defaultMaxSummaryChars = 12_000

    private let makeContainer: @Sendable () throws -> ModelContainer
    private let lock = NSLock()
    private var cachedContainer: ModelContainer?
    private let compactedLineLimit = 500

    public init(
        makeContainer: @escaping @Sendable () throws -> ModelContainer = { try TicketPartyPersistence.makeSharedContainer() }
    ) {
        self.makeContainer = makeContainer
    }

    @discardableResult
    public func ensureThread(ticketID: UUID) throws -> TicketConversationThreadRecord {
        let context = try makeContext()
        if let existing = try fetchThread(ticketID: ticketID, context: context) {
            return mapThread(existing)
        }

        let now = Date()
        let thread = TicketConversationThread(
            ticketID: ticketID,
            mode: .plan,
            rollingSummary: "",
            lastCompactedSequence: 0,
            createdAt: now,
            updatedAt: now
        )
        context.insert(thread)
        try context.save()
        return mapThread(thread)
    }

    public func mode(ticketID: UUID) throws -> TicketConversationMode {
        let context = try makeContext()
        guard let thread = try fetchThread(ticketID: ticketID, context: context) else {
            throw StoreError.threadNotFound(ticketID)
        }
        return thread.mode
    }

    public func setMode(ticketID: UUID, mode: TicketConversationMode) throws {
        let context = try makeContext()
        let thread = try ensureThreadModel(ticketID: ticketID, context: context)
        guard thread.mode != mode else { return }
        thread.mode = mode
        thread.updatedAt = .now
        try context.save()
    }

    @discardableResult
    public func appendUserMessage(ticketID: UUID, text: String) throws -> TicketConversationMessageRecord {
        try appendMessage(
            ticketID: ticketID,
            role: .user,
            status: .completed,
            content: text,
            requiresResponse: false,
            runID: nil
        )
    }

    @discardableResult
    public func appendSystemMessage(ticketID: UUID, text: String) throws -> TicketConversationMessageRecord {
        try appendMessage(
            ticketID: ticketID,
            role: .system,
            status: .completed,
            content: text,
            requiresResponse: false,
            runID: nil
        )
    }

    @discardableResult
    public func beginAssistantMessage(ticketID: UUID, runID: UUID?) throws -> TicketConversationMessageRecord {
        try appendMessage(
            ticketID: ticketID,
            role: .assistant,
            status: .streaming,
            content: "",
            requiresResponse: false,
            runID: runID
        )
    }

    public func appendAssistantOutput(ticketID: UUID, line: String) throws {
        let context = try makeContext()
        let message = try streamingAssistantMessage(ticketID: ticketID, context: context)
        message.content = joinMessageContent(existing: message.content, addition: line)
        message.updatedAt = .now
        try context.save()
    }

    public func completeAssistantMessage(ticketID: UUID, success: Bool, errorSummary: String?) throws {
        let context = try makeContext()
        let message = try streamingAssistantMessage(ticketID: ticketID, context: context)
        let now = Date()

        if success {
            message.status = .completed
        } else if errorSummary?.localizedCaseInsensitiveContains("cancelled") == true {
            message.status = .cancelled
        } else {
            message.status = .failed
        }

        if success == false, let errorSummary {
            let normalizedSummary = errorSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedSummary.isEmpty == false {
                message.content = joinMessageContent(existing: message.content, addition: normalizedSummary)
            }
        }

        message.requiresResponse = requiresResponse(content: message.content)
        message.updatedAt = now
        try context.save()
    }

    public func messages(ticketID: UUID, limit: Int? = nil) throws -> [TicketConversationMessageRecord] {
        if let limit, limit <= 0 {
            return []
        }

        let context = try makeContext()

        if let limit {
            var descriptor = FetchDescriptor<TicketConversationMessage>(
                predicate: #Predicate<TicketConversationMessage> { message in
                    message.ticketID == ticketID
                },
                sortBy: [SortDescriptor(\TicketConversationMessage.sequence, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            let tailMessages = try context.fetch(descriptor)
            return tailMessages.reversed().map(mapMessage)
        }

        let descriptor = FetchDescriptor<TicketConversationMessage>(
            predicate: #Predicate<TicketConversationMessage> { message in
                message.ticketID == ticketID
            },
            sortBy: [SortDescriptor(\TicketConversationMessage.sequence, order: .forward)]
        )
        return try context.fetch(descriptor).map(mapMessage)
    }

    public func replayBundle(
        ticketID: UUID,
        windowCount: Int = TicketConversationStore.defaultWindowCount,
        maxSummaryChars: Int = TicketConversationStore.defaultMaxSummaryChars
    ) throws -> (mode: TicketConversationMode, summary: String, messages: [TicketConversationMessageRecord]) {
        try compactIfNeeded(ticketID: ticketID, windowCount: windowCount, maxSummaryChars: maxSummaryChars)

        let context = try makeContext()
        let thread = try ensureThreadModel(ticketID: ticketID, context: context)
        let allMessages = try fetchMessages(ticketID: ticketID, context: context)
        let replayMessages = filteredReplayMessages(from: allMessages, windowCount: windowCount).map(mapMessage)
        return (thread.mode, thread.rollingSummary, replayMessages)
    }

    public func compactIfNeeded(
        ticketID: UUID,
        windowCount: Int = TicketConversationStore.defaultWindowCount,
        maxSummaryChars: Int = TicketConversationStore.defaultMaxSummaryChars
    ) throws {
        let clampedWindowCount = max(1, windowCount)
        let clampedSummaryChars = max(0, maxSummaryChars)

        let context = try makeContext()
        let thread = try ensureThreadModel(ticketID: ticketID, context: context)
        let allMessages = try fetchMessages(ticketID: ticketID, context: context)
        guard allMessages.count > clampedWindowCount else {
            return
        }

        let compactableCount = allMessages.count - clampedWindowCount
        let compactableMessages = Array(allMessages.prefix(compactableCount))
        let newCompacted = compactableMessages.filter { $0.sequence > thread.lastCompactedSequence }

        if newCompacted.isEmpty == false {
            var summaryLines = summaryLines(from: thread.rollingSummary)
            for message in newCompacted {
                summaryLines.append(compactedLine(for: message))
            }
            summaryLines = trimSummaryLines(summaryLines, maxSummaryChars: clampedSummaryChars)
            thread.rollingSummary = summaryLines.joined(separator: "\n")
            if let lastCompacted = compactableMessages.last {
                thread.lastCompactedSequence = lastCompacted.sequence
            }
        }

        for message in compactableMessages {
            context.delete(message)
        }

        thread.updatedAt = .now
        try context.save()
    }

    private func appendMessage(
        ticketID: UUID,
        role: TicketConversationRole,
        status: TicketConversationMessageStatus,
        content: String,
        requiresResponse: Bool,
        runID: UUID?
    ) throws -> TicketConversationMessageRecord {
        let context = try makeContext()
        let thread = try ensureThreadModel(ticketID: ticketID, context: context)
        let sequence = try nextSequence(ticketID: ticketID, context: context)
        let now = Date()
        let message = TicketConversationMessage(
            threadID: thread.id,
            ticketID: ticketID,
            sequence: sequence,
            role: role,
            status: status,
            content: content,
            requiresResponse: requiresResponse,
            runID: runID,
            createdAt: now,
            updatedAt: now
        )

        context.insert(message)
        thread.updatedAt = now
        try context.save()
        return mapMessage(message)
    }

    private func fetchMessages(ticketID: UUID, context: ModelContext) throws -> [TicketConversationMessage] {
        let descriptor = FetchDescriptor<TicketConversationMessage>(
            predicate: #Predicate<TicketConversationMessage> { message in
                message.ticketID == ticketID
            },
            sortBy: [SortDescriptor(\TicketConversationMessage.sequence, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    private func filteredReplayMessages(
        from messages: [TicketConversationMessage],
        windowCount: Int
    ) -> [TicketConversationMessage] {
        let replayable = messages.filter { message in
            message.status != .streaming && message.status != .pending
        }
        guard replayable.count > windowCount else {
            return replayable
        }
        return Array(replayable.suffix(windowCount))
    }

    private func fetchThread(ticketID: UUID, context: ModelContext) throws -> TicketConversationThread? {
        let descriptor = FetchDescriptor<TicketConversationThread>(
            predicate: #Predicate<TicketConversationThread> { thread in
                thread.ticketID == ticketID
            }
        )
        return try context.fetch(descriptor).first
    }

    private func ensureThreadModel(ticketID: UUID, context: ModelContext) throws -> TicketConversationThread {
        if let thread = try fetchThread(ticketID: ticketID, context: context) {
            return thread
        }

        let now = Date()
        let thread = TicketConversationThread(
            ticketID: ticketID,
            mode: .plan,
            rollingSummary: "",
            lastCompactedSequence: 0,
            createdAt: now,
            updatedAt: now
        )
        context.insert(thread)
        try context.save()
        return thread
    }

    private func nextSequence(ticketID: UUID, context: ModelContext) throws -> Int64 {
        var descriptor = FetchDescriptor<TicketConversationMessage>(
            predicate: #Predicate<TicketConversationMessage> { message in
                message.ticketID == ticketID
            },
            sortBy: [SortDescriptor(\TicketConversationMessage.sequence, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let lastSequence = try context.fetch(descriptor).first?.sequence ?? 0
        return lastSequence + 1
    }

    private func streamingAssistantMessage(ticketID: UUID, context: ModelContext) throws -> TicketConversationMessage {
        let assistantRoleRaw = TicketConversationRole.assistant.rawValue
        let streamingRaw = TicketConversationMessageStatus.streaming.rawValue
        var descriptor = FetchDescriptor<TicketConversationMessage>(
            predicate: #Predicate<TicketConversationMessage> { message in
                message.ticketID == ticketID &&
                    message.roleRaw == assistantRoleRaw &&
                    message.statusRaw == streamingRaw
            },
            sortBy: [SortDescriptor(\TicketConversationMessage.sequence, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        if let message = try context.fetch(descriptor).first {
            return message
        }
        throw StoreError.streamingAssistantMessageNotFound(ticketID)
    }

    private func joinMessageContent(existing: String, addition: String) -> String {
        guard addition.isEmpty == false else { return existing }
        if existing.isEmpty {
            return addition
        }
        return existing + "\n" + addition
    }

    private func summaryLines(from summary: String) -> [String] {
        summary
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func compactedLine(for message: TicketConversationMessage) -> String {
        let flattened = message.content
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = if trimmed.isEmpty {
            "(empty)"
        } else if trimmed.count > compactedLineLimit {
            String(trimmed.prefix(compactedLineLimit)) + "..."
        } else {
            trimmed
        }
        return "\(message.role.rawValue): \(body)"
    }

    private func trimSummaryLines(_ lines: [String], maxSummaryChars: Int) -> [String] {
        guard maxSummaryChars > 0 else { return [] }

        var trimmed = lines
        while trimmed.isEmpty == false && trimmed.joined(separator: "\n").count > maxSummaryChars {
            trimmed.removeFirst()
        }
        return trimmed
    }

    private func requiresResponse(content: String) -> Bool {
        let tailCount = 500
        let tail = String(content.suffix(tailCount))
        return tail.contains("?")
    }

    private func mapThread(_ thread: TicketConversationThread) -> TicketConversationThreadRecord {
        TicketConversationThreadRecord(
            id: thread.id,
            ticketID: thread.ticketID,
            mode: thread.mode,
            rollingSummary: thread.rollingSummary,
            lastCompactedSequence: thread.lastCompactedSequence,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt
        )
    }

    private func mapMessage(_ message: TicketConversationMessage) -> TicketConversationMessageRecord {
        TicketConversationMessageRecord(
            id: message.id,
            threadID: message.threadID,
            ticketID: message.ticketID,
            sequence: message.sequence,
            role: message.role,
            status: message.status,
            content: message.content,
            requiresResponse: message.requiresResponse,
            runID: message.runID,
            createdAt: message.createdAt,
            updatedAt: message.updatedAt
        )
    }

    private func makeContext() throws -> ModelContext {
        try ModelContext(sharedContainer())
    }

    private func sharedContainer() throws -> ModelContainer {
        lock.lock()
        defer { lock.unlock() }

        if let cachedContainer {
            return cachedContainer
        }

        let container = try makeContainer()
        cachedContainer = container
        return container
    }
}
