# Task Ordering Plan (SwiftData)

## Goal

Allow users to edit task order with low-write updates and predictable behavior in active lists.

## Data Model

- Add `orderKey: Int64` to `Task`.
- Keep ordering scoped to where users actually sort:
  - `projectID` (required)
  - `stateID` (optional, for Kanban lanes)
- Keep standard lifecycle fields (`closedAt`, `archivedAt`) and treat active vs done as separate ordering scopes.

Example:

```swift
@Model
final class Task {
    @Attribute(.unique) var id: UUID
    var projectID: UUID
    var stateID: UUID?
    var title: String
    var orderKey: Int64
    var createdAt: Date
    var updatedAt: Date
    var closedAt: Date?
    var archivedAt: Date?
}
```

## Query and Sort Rules

- Active list query:
  - Filter to active tasks (`closedAt == nil`, `archivedAt == nil`)
  - Scope by `projectID` (+ `stateID` when needed)
- Sort by:
  - `orderKey` ascending
  - `createdAt` ascending as stable tie-breaker

## Ordering Algorithm

1. Seed new tasks with spaced keys (for example, step `1024`).
2. On drag/drop reorder:
   - Find previous and next tasks in the destination scope.
   - Set moved task `orderKey` to midpoint between neighbor keys.
3. If no integer gap exists between neighbors:
   - Rebalance only the destination scope (not global).
   - Reassign spaced keys (`1024`, `2048`, `3072`, ...).

## Rebalance Scope Policy

- Do not include all past/done tasks by default.
- Rebalance only the list users are actively arranging:
  - Same `projectID`
  - Same `stateID` (if lane-based)
  - Usually active-only (`closedAt == nil`, `archivedAt == nil`)
- Handle done/history separately:
  - Either a separate order scope, or
  - A fixed sort like `closedAt DESC` if manual ordering is unnecessary.

## Move Between Lanes

- When moving task A from lane X to lane Y:
  - Update `stateID` to lane Y.
  - Assign a new `orderKey` using neighbors in lane Y.
  - Do not rebalance lane X unless needed.

## Concurrency and Integrity Notes

- Wrap reorder + save in one context transaction.
- If concurrent edits cause collisions, detect duplicate/adjacent-tight keys and trigger local rebalance for that scope.
- Keep rebalance idempotent and cheap by limiting it to one scope at a time.

## Implementation Steps

1. Add `orderKey` to `Task` model and migration/update path.
2. Update task queries to sort by `orderKey`, then `createdAt`.
3. Implement reorder API:
   - `moveTask(taskID, destinationScope, beforeTaskID?, afterTaskID?)`
4. Implement `rebalance(scope:)` helper for active scope only.
5. Add tests:
   - Insert ordering with gaps
   - Midpoint reorder
   - Rebalance on exhausted gap
   - Cross-lane move
   - Active-only rebalance excludes done tasks
