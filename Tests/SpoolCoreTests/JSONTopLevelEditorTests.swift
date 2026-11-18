import Foundation
import Testing
@testable import SpoolCore

struct JSONTopLevelEditorTests {
    let spoolValue = #"{"type":"command","command":"/x/spool-statusline"}"#

    func original() throws -> String {
        String(decoding: try fixture("settings-realistic"), as: UTF8.self)
    }

    func parse(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func insertPreservesEverythingElse() throws {
        let text = try original()
        let edited = try JSONTopLevelEditor.setting(spoolValue, forKey: "statusLine", in: text)
        let object = try parse(edited)
        #expect(object["statusLine"] != nil)
        #expect(object["theme"] as? String == "dark")
        #expect(edited.contains("\n  \"statusLine\": " + spoolValue))
        #expect(try JSONTopLevelEditor.removing(key: "statusLine", in: edited) == text)
        #expect(try JSONTopLevelEditor.value(forKey: "statusLine", in: edited) == spoolValue)
    }

    @Test func nestedStatusLineIsNotTopLevel() throws {
        #expect(try JSONTopLevelEditor.value(forKey: "statusLine", in: original()) == nil)
        #expect(try JSONTopLevelEditor.value(forKey: "theme", in: original()) == "\"dark\"")
    }

    @Test func replaceExistingValue() throws {
        let text = "{\n  \"a\": 1,\n  \"statusLine\": {\"type\":\"command\",\"command\":\"echo '{}'\"},\n  \"b\": 2\n}\n"
        let edited = try JSONTopLevelEditor.setting(spoolValue, forKey: "statusLine", in: text)
        #expect(edited == "{\n  \"a\": 1,\n  \"statusLine\": \(spoolValue),\n  \"b\": 2\n}\n")
    }

    @Test func removeFirstMiddleLast() throws {
        let text = "{\n  \"a\": 1,\n  \"statusLine\": {\"x\": [1, 2]},\n  \"b\": 2\n}\n"
        let middle = try JSONTopLevelEditor.removing(key: "statusLine", in: text)
        #expect(try parse(middle).keys.sorted() == ["a", "b"])
        let first = "{\n  \"statusLine\": \"s\",\n  \"a\": 1,\n  \"b\": 2\n}\n"
        #expect(try JSONTopLevelEditor.removing(key: "statusLine", in: first) == "{\n  \"a\": 1,\n  \"b\": 2\n}\n")
        let last = "{\n  \"a\": 1,\n  \"b\": 2,\n  \"statusLine\": \"s\"\n}\n"
        #expect(try JSONTopLevelEditor.removing(key: "statusLine", in: last) == "{\n  \"a\": 1,\n  \"b\": 2\n}\n")
        let only = "{\n  \"statusLine\": \"s\"\n}\n"
        #expect(try parse(JSONTopLevelEditor.removing(key: "statusLine", in: only)).isEmpty)
        #expect(try JSONTopLevelEditor.removing(key: "zzz", in: text) == text)
    }

    @Test func emptyObject() throws {
        let edited = try JSONTopLevelEditor.setting(spoolValue, forKey: "statusLine", in: "{}")
        #expect(edited == "{\n  \"statusLine\": \(spoolValue)\n}")
        #expect(try parse(edited)["statusLine"] != nil)
        #expect(try JSONTopLevelEditor.removing(key: "statusLine", in: edited) == "{}")
    }

    @Test func crlfAndTabIndentation() throws {
        let text = "{\r\n\t\"a\": 1\r\n}\r\n"
        let edited = try JSONTopLevelEditor.setting(spoolValue, forKey: "statusLine", in: text)
        #expect(edited == "{\r\n\t\"a\": 1,\r\n\t\"statusLine\": \(spoolValue)\r\n}\r\n")
        #expect(try JSONTopLevelEditor.removing(key: "statusLine", in: edited) == text)
    }

    @Test func invalidJSONThrows() {
        #expect(throws: SpoolError.malformedJSON) {
            try JSONTopLevelEditor.setting(spoolValue, forKey: "statusLine", in: "{\"a\": 1,")
        }
        #expect(throws: SpoolError.malformedJSON) {
            try JSONTopLevelEditor.value(forKey: "a", in: "{\"a\": 1,}")
        }
        #expect(throws: SpoolError.malformedJSON) {
            try JSONTopLevelEditor.removing(key: "a", in: "")
        }
        #expect(throws: SpoolError.malformedJSON) {
            try JSONTopLevelEditor.setting("{bad", forKey: "a", in: "{}")
        }
    }

    @Test func duplicateKeyReadsTheLastAndIsNeverEdited() throws {
        let text = "{\n  \"statusLine\": \"first\",\n  \"a\": 1,\n  \"statusLine\": \"last\"\n}\n"
        // What JSON.parse in Claude Code keeps.
        #expect(try JSONTopLevelEditor.value(forKey: "statusLine", in: text) == "\"last\"")
        #expect(throws: SpoolError.duplicateKey("statusLine")) {
            try JSONTopLevelEditor.setting(spoolValue, forKey: "statusLine", in: text)
        }
        #expect(throws: SpoolError.duplicateKey("statusLine")) {
            try JSONTopLevelEditor.removing(key: "statusLine", in: text)
        }
        // Other keys still edit normally.
        #expect(try JSONTopLevelEditor.setting("2", forKey: "a", in: text)
            == "{\n  \"statusLine\": \"first\",\n  \"a\": 2,\n  \"statusLine\": \"last\"\n}\n")
        #expect(try JSONTopLevelEditor.removing(key: "a", in: text)
            == "{\n  \"statusLine\": \"first\",\n  \"statusLine\": \"last\"\n}\n")
        #expect(try JSONTopLevelEditor.setting("true", forKey: "b", in: text)
            == "{\n  \"statusLine\": \"first\",\n  \"a\": 1,\n  \"statusLine\": \"last\",\n  \"b\": true\n}\n")
    }

    @Test func insertKeepsAnInlineObjectOnOneLine() throws {
        #expect(try JSONTopLevelEditor.setting("2", forKey: "b", in: #"{"a": 1}"#) == #"{"a": 1, "b": 2}"#)
        #expect(try JSONTopLevelEditor.setting("2", forKey: "b", in: #"  {"a": [1, 2], "c": {"d": 3}}  "#)
            == #"  {"a": [1, 2], "c": {"d": 3}, "b": 2}  "#)
    }

    @Test func insertUsesTheObjectsOwnIndentation() throws {
        // The first member shares the line of the brace; the next one shows the indentation.
        let text = "{\"a\": 1,\n      \"c\": 3\n}"
        #expect(try JSONTopLevelEditor.setting("2", forKey: "b", in: text) == "{\"a\": 1,\n      \"c\": 3,\n      \"b\": 2\n}")
    }

    @Test func topLevelArrayThrows() {
        #expect(throws: SpoolError.notAnObject) {
            try JSONTopLevelEditor.setting(spoolValue, forKey: "statusLine", in: "[]")
        }
    }
}
