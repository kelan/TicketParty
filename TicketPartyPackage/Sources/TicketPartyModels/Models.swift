//
//  Models.swift
//  TicketParty
//
//  Created by Codex on 2/10/26.
//

import Foundation

public enum TicketSize: String, Codable, CaseIterable, Sendable {
    case quickTweak = "quick_tweak"
    case straightforwardFeature = "straightforward_feature"
    case requiresThinking = "requires_thinking"
    case majorRefactor = "major_refactor"
}

public enum TicketSeverity: String, Codable, CaseIterable, Sendable {
    case trivial
    case minor
    case major
    case critical
}

public enum AuthorType: String, Codable, CaseIterable, Sendable {
    case owner
    case agent
    case system
}

public enum CommentType: String, Codable, CaseIterable, Sendable {
    case update
    case question
    case answer
    case decision
    case statusChange = "status_change"
}

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case localCLI = "local_cli"
    case apiBacked = "api_backed"
    case manual
}

public enum TicketEventType: String, Codable, CaseIterable, Sendable {
    case created
    case updated
    case stateChanged = "state_changed"
    case assignmentChanged = "assignment_changed"
    case noteAdded = "note_added"
    case commentAdded = "comment_added"
    case questionAsked = "question_asked"
    case questionAnswered = "question_answered"
    case closed
    case reopened
    case archived
    case unarchived
}

public enum ActorType: String, Codable, CaseIterable, Sendable {
    case owner
    case agent
    case system
}

public enum SessionMarkerType: String, Codable, CaseIterable, Sendable {
    case appActive = "app_active"
    case appInactive = "app_inactive"
    case digestViewed = "digest_viewed"
}

public struct TicketSummary: Codable, Hashable, Sendable {
    public let id: UUID
    public let displayID: String
    public let title: String
    public let size: String
    public let severity: String
    public let updatedAt: Date

    public init(
        id: UUID,
        displayID: String,
        title: String,
        size: String,
        severity: String,
        updatedAt: Date
    ) {
        self.id = id
        self.displayID = displayID
        self.title = title
        self.size = size
        self.severity = severity
        self.updatedAt = updatedAt
    }
}

public struct TicketDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let ticketNumber: Int
    public let displayID: String
    public let title: String
    public let description: String
    public let size: TicketSize
    public let severity: TicketSeverity
    public let workflowID: UUID?
    public let stateID: UUID?
    public let assigneeID: UUID?
    public let createdAt: Date
    public let updatedAt: Date
    public let closedAt: Date?
    public let archivedAt: Date?

    public init(
        id: UUID,
        ticketNumber: Int,
        displayID: String,
        title: String,
        description: String,
        size: TicketSize,
        severity: TicketSeverity,
        workflowID: UUID?,
        stateID: UUID?,
        assigneeID: UUID?,
        createdAt: Date,
        updatedAt: Date,
        closedAt: Date?,
        archivedAt: Date?
    ) {
        self.id = id
        self.ticketNumber = ticketNumber
        self.displayID = displayID
        self.title = title
        self.description = description
        self.size = size
        self.severity = severity
        self.workflowID = workflowID
        self.stateID = stateID
        self.assigneeID = assigneeID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.archivedAt = archivedAt
    }
}

public struct NoteDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let ticketID: UUID
    public let body: String
    public let authorType: AuthorType
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        ticketID: UUID,
        body: String,
        authorType: AuthorType,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.ticketID = ticketID
        self.body = body
        self.authorType = authorType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CommentDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let ticketID: UUID
    public let authorType: AuthorType
    public let authorID: String?
    public let type: CommentType
    public let body: String
    public let createdAt: Date
    public let inReplyToCommentID: UUID?
    public let requiresResponse: Bool
    public let resolvedAt: Date?

    public init(
        id: UUID,
        ticketID: UUID,
        authorType: AuthorType,
        authorID: String?,
        type: CommentType,
        body: String,
        createdAt: Date,
        inReplyToCommentID: UUID?,
        requiresResponse: Bool,
        resolvedAt: Date?
    ) {
        self.id = id
        self.ticketID = ticketID
        self.authorType = authorType
        self.authorID = authorID
        self.type = type
        self.body = body
        self.createdAt = createdAt
        self.inReplyToCommentID = inReplyToCommentID
        self.requiresResponse = requiresResponse
        self.resolvedAt = resolvedAt
    }
}

public struct WorkflowDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let isDefault: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        name: String,
        isDefault: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WorkflowStateDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let workflowID: UUID
    public let key: String
    public let displayName: String
    public let orderIndex: Int
    public let isTerminal: Bool

    public init(
        id: UUID,
        workflowID: UUID,
        key: String,
        displayName: String,
        orderIndex: Int,
        isTerminal: Bool
    ) {
        self.id = id
        self.workflowID = workflowID
        self.key = key
        self.displayName = displayName
        self.orderIndex = orderIndex
        self.isTerminal = isTerminal
    }
}

public struct WorkflowTransitionDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let workflowID: UUID
    public let fromStateID: UUID
    public let toStateID: UUID
    public let label: String
    public let guardExpression: String?

    public init(
        id: UUID,
        workflowID: UUID,
        fromStateID: UUID,
        toStateID: UUID,
        label: String,
        guardExpression: String?
    ) {
        self.id = id
        self.workflowID = workflowID
        self.fromStateID = fromStateID
        self.toStateID = toStateID
        self.label = label
        self.guardExpression = guardExpression
    }
}

public struct AssignmentDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let ticketID: UUID
    public let assigneeID: UUID
    public let assignedBy: String
    public let assignedAt: Date
    public let unassignedAt: Date?

    public init(
        id: UUID,
        ticketID: UUID,
        assigneeID: UUID,
        assignedBy: String,
        assignedAt: Date,
        unassignedAt: Date?
    ) {
        self.id = id
        self.ticketID = ticketID
        self.assigneeID = assigneeID
        self.assignedBy = assignedBy
        self.assignedAt = assignedAt
        self.unassignedAt = unassignedAt
    }
}

public struct AgentDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: AgentKind
    public let isActive: Bool

    public init(id: UUID, name: String, kind: AgentKind, isActive: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isActive = isActive
    }
}

public struct TicketEventDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let ticketID: UUID
    public let eventType: TicketEventType
    public let actorType: ActorType
    public let actorID: String?
    public let timestamp: Date
    public let payloadJSON: String

    public init(
        id: UUID,
        ticketID: UUID,
        eventType: TicketEventType,
        actorType: ActorType,
        actorID: String?,
        timestamp: Date,
        payloadJSON: String
    ) {
        self.id = id
        self.ticketID = ticketID
        self.eventType = eventType
        self.actorType = actorType
        self.actorID = actorID
        self.timestamp = timestamp
        self.payloadJSON = payloadJSON
    }
}

public struct SessionMarkerDTO: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let type: SessionMarkerType
    public let timestamp: Date

    public init(id: UUID, type: SessionMarkerType, timestamp: Date) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
    }
}
