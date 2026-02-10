//
//  Models.swift
//  TicketParty
//
//  Created by Codex on 2/10/26.
//

import Foundation
import SwiftData

enum TaskPriority: String, Codable, CaseIterable {
    case low
    case medium
    case high
    case urgent
}

enum TaskSeverity: String, Codable, CaseIterable {
    case trivial
    case minor
    case major
    case critical
}

enum AuthorType: String, Codable, CaseIterable {
    case owner
    case agent
    case system
}

enum CommentType: String, Codable, CaseIterable {
    case update
    case question
    case answer
    case decision
    case statusChange = "status_change"
}

enum AgentKind: String, Codable, CaseIterable {
    case localCLI = "local_cli"
    case apiBacked = "api_backed"
    case manual
}

enum TaskEventType: String, Codable, CaseIterable {
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

enum ActorType: String, Codable, CaseIterable {
    case owner
    case agent
    case system
}

enum SessionMarkerType: String, Codable, CaseIterable {
    case appActive = "app_active"
    case appInactive = "app_inactive"
    case digestViewed = "digest_viewed"
}

@Model
final class Task {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var ticketNumber: Int
    @Attribute(.unique) var displayID: String
    var title: String
    var taskDescription: String
    var priority: TaskPriority
    var severity: TaskSeverity
    var workflowID: UUID?
    var stateID: UUID?
    var assigneeID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var closedAt: Date?
    var archivedAt: Date?

    init(
        id: UUID = UUID(),
        ticketNumber: Int,
        displayID: String,
        title: String,
        description: String = "",
        priority: TaskPriority = .medium,
        severity: TaskSeverity = .major,
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
        self.title = title
        self.taskDescription = description
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
    var taskID: UUID
    var body: String
    var authorType: AuthorType
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        taskID: UUID,
        body: String,
        authorType: AuthorType,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.taskID = taskID
        self.body = body
        self.authorType = authorType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class Comment {
    @Attribute(.unique) var id: UUID
    var taskID: UUID
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
        taskID: UUID,
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
        self.taskID = taskID
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
    var taskID: UUID
    var assigneeID: UUID
    var assignedBy: String
    var assignedAt: Date
    var unassignedAt: Date?

    init(
        id: UUID = UUID(),
        taskID: UUID,
        assigneeID: UUID,
        assignedBy: String,
        assignedAt: Date = .now,
        unassignedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
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
final class TaskEvent {
    @Attribute(.unique) var id: UUID
    var taskID: UUID
    var eventType: TaskEventType
    var actorType: ActorType
    var actorID: String?
    var timestamp: Date
    var payloadJSON: String

    init(
        id: UUID = UUID(),
        taskID: UUID,
        eventType: TaskEventType,
        actorType: ActorType,
        actorID: String? = nil,
        timestamp: Date = .now,
        payloadJSON: String = "{}"
    ) {
        self.id = id
        self.taskID = taskID
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
