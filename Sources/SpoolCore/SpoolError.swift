public enum SpoolError: Error, Equatable, Sendable {
    case malformedJSON
    case notAnObject
    case missingField(String)
    case io(String)
    case duplicateKey(String)
    /// A key occurs more than once inside the value of the top-level key `entry`.
    case duplicateKeyInEntry(entry: String, key: String)
}
