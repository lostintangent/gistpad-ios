extension Gist {
    public func withCommentCount(_ count: Int?) -> Gist {
        Gist(
            id: id, description: description, files: files,
            updatedAt: updatedAt, createdAt: createdAt, isPublic: isPublic,
            owner: owner, truncated: truncated, history: history, commentCount: count)
    }
}
