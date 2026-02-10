import Foundation
import SwiftData
import TicketPartyModels

@Model
public final class Project {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var statusText: String
    public var summary: String
    public var workingDirectory: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        statusText: String = "",
        summary: String = "",
        workingDirectory: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.statusText = statusText
        self.summary = summary
        self.workingDirectory = workingDirectory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}

@Model
public final class Ticket {
    @Attribute(.unique) public var id: UUID
    @Attribute(.unique) public var ticketNumber: Int
    @Attribute(.unique) public var displayID: String
    public var projectID: UUID?
    public var orderKey: Int64 = 0
    public var title: String
    public var ticketDescription: String
    public var priority: TicketPriority
    public var severity: TicketSeverity
    public var workflowID: UUID?
    public var stateID: UUID?
    public var assigneeID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var closedAt: Date?
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        ticketNumber: Int,
        displayID: String,
        projectID: UUID? = nil,
        orderKey: Int64 = 0,
        title: String,
        description: String = "",
        priority: TicketPriority = .medium,
        severity: TicketSeverity = .major,
        workflowID: UUID? = nil,
        stateID: UUID? = nil,
        assigneeID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        closedAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.ticketNumber = ticketNumber
        self.displayID = displayID
        self.projectID = projectID
        self.orderKey = orderKey
        self.title = title
        ticketDescription = description
        self.priority = priority
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

@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var ticketID: UUID
    var body: String
    var authorType: AuthorType
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        ticketID: UUID,
        body: String,
        authorType: AuthorType,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.ticketID = ticketID
        self.body = body
        self.authorType = authorType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Comment {
    @Attribute(.unique) var id: UUID
    var ticketID: UUID
    var authorType: AuthorType
    var authorID: String?
    var type: CommentType
    var body: String
    var createdAt: Date
    var inReplyToCommentID: UUID?
    var requiresResponse: Bool
    var resolvedAt: Date?

    init(
        id: UUID = UUID(),
        ticketID: UUID,
        authorType: AuthorType,
        authorID: String? = nil,
        type: CommentType,
        body: String,
        createdAt: Date = .now,
        inReplyToCommentID: UUID? = nil,
        requiresResponse: Bool = false,
        resolvedAt: Date? = nil
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

@Model
final class Workflow {
    @Attribute(.unique) var id: UUID
    var name: String
    var isDefault: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        isDefault: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class WorkflowState {
    @Attribute(.unique) var id: UUID
    var workflowID: UUID
    var key: String
    var displayName: String
    var orderIndex: Int
    var isTerminal: Bool

    init(
        id: UUID = UUID(),
        workflowID: UUID,
        key: String,
        displayName: String,
        orderIndex: Int,
        isTerminal: Bool = false
    ) {
        self.id = id
        self.workflowID = workflowID
        self.key = key
        self.displayName = displayName
        self.orderIndex = orderIndex
        self.isTerminal = isTerminal
    }
}

@Model
final class WorkflowTransition {
    @Attribute(.unique) var id: UUID
    var workflowID: UUID
    var fromStateID: UUID
    var toStateID: UUID
    var label: String
    var guardExpression: String?

    init(
        id: UUID = UUID(),
        workflowID: UUID,
        fromStateID: UUID,
        toStateID: UUID,
        label: String,
        guardExpression: String? = nil
    ) {
        self.id = id
        self.workflowID = workflowID
        self.fromStateID = fromStateID
        self.toStateID = toStateID
        self.label = label
        self.guardExpression = guardExpression
    }
}

@Model
final class Assignment {
    @Attribute(.unique) var id: UUID
    var ticketID: UUID
    var assigneeID: UUID
    var assignedBy: String
    var assignedAt: Date
    var unassignedAt: Date?

    init(
        id: UUID = UUID(),
        ticketID: UUID,
        assigneeID: UUID,
        assignedBy: String,
        assignedAt: Date = .now,
        unassignedAt: Date? = nil
    ) {
        self.id = id
        self.ticketID = ticketID
        self.assigneeID = assigneeID
        self.assignedBy = assignedBy
        self.assignedAt = assignedAt
        self.unassignedAt = unassignedAt
    }
}

@Model
final class Agent {
    @Attribute(.unique) var id: UUID
    var name: String
    var kind: AgentKind
    var isActive: Bool

    init(
        id: UUID = UUID(),
        name: String,
        kind: AgentKind,
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isActive = isActive
    }
}

@Model
final class TicketEvent {
    @Attribute(.unique) var id: UUID
    var ticketID: UUID
    var eventType: TicketEventType
    var actorType: ActorType
    var actorID: String?
    var timestamp: Date
    var payloadJSON: String

    init(
        id: UUID = UUID(),
        ticketID: UUID,
        eventType: TicketEventType,
        actorType: ActorType,
        actorID: String? = nil,
        timestamp: Date = .now,
        payloadJSON: String = "{}"
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

@Model
final class SessionMarker {
    @Attribute(.unique) var id: UUID
    var type: SessionMarkerType
    var timestamp: Date

    init(
        id: UUID = UUID(),
        type: SessionMarkerType,
        timestamp: Date = .now
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
    }
}
