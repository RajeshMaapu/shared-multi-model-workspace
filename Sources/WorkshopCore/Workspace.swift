import Foundation

public struct TaskWorkspace: Codable, Equatable, Sendable {
    public var taskID: TaskID
    public var repositoryPath: String?
    public var branch: String?
    public var path: String
    public var baseRevision: String?
    public var state: String

    public init(taskID: TaskID, repositoryPath: String? = nil, branch: String? = nil,
                path: String, baseRevision: String? = nil, state: String = "ready") {
        self.taskID = taskID
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.path = path
        self.baseRevision = baseRevision
        self.state = state
    }
}
