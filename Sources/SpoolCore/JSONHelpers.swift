import Foundation

enum JSONHelpers {
    static func object(_ data: Data) throws -> [String: Any] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SpoolError.malformedJSON
        }
        guard let object = root as? [String: Any] else { throw SpoolError.notAnObject }
        return object
    }
}
