import Testing
@testable import Lithe

struct CommandLineDisplayFormatterTests {
    @Test func agentSettingsJSONIsIndentedUnderItsOption() {
        let display = CommandLineDisplayFormatter.format(
            #"/usr/local/bin/claude --output-format stream-json --verbose --resume=abc --settings {"apiKeyHelper":"","env":{"BASE_URL":"http://127.0.0.1:8080/x","RETRIES":"0"}}"#
        )
        #expect(display.text == """
        /usr/local/bin/claude
          --output-format stream-json
          --verbose
          --resume=abc
          --settings {
            "apiKeyHelper": "",
            "env": {
              "BASE_URL": "http://127.0.0.1:8080/x",
              "RETRIES": "0"
            }
          }
        """)
    }

    @Test func jsonKeepsKeyOrderEscapesAndScalarRoles() {
        let display = CommandLineDisplayFormatter.format(#"tool {"z":"a\"b","a":[1,-2.5e3,true,null],"m":{},"n":[]}"#)
        #expect(display.text == """
        tool {
          "z": "a\\"b",
          "a": [
            1,
            -2.5e3,
            true,
            null
          ],
          "m": {},
          "n": []
        }
        """)
        let runs = display.lines.flatMap { $0 }
        #expect(runs.contains(.init(text: "\"z\"", role: .jsonKey)))
        #expect(runs.contains(.init(text: #""a\"b""#, role: .jsonString)))
        #expect(runs.contains(.init(text: "-2.5e3", role: .jsonNumber)))
        #expect(runs.contains(.init(text: "true", role: .jsonLiteral)))
        #expect(runs.contains(.init(text: "[]", role: .jsonPunctuation)))
    }

    @Test func attachedAndQuotedJSONArgumentsAreRecognized() {
        #expect(CommandLineDisplayFormatter.format(#"run --config={"a":1}"#).text == """
        run
          --config={
            "a": 1
          }
        """)
        #expect(CommandLineDisplayFormatter.format(#"sh -c '{"a":[2]}'"#).text == """
        sh -c '{
          "a": [
            2
          ]
        }'
        """)
    }

    /// Shell syntax that only looks like JSON must stay exactly as reported.
    @Test func bracesThatAreNotJSONStayUnchanged() {
        for command in [
            "sh -c [ -f build.lock ] && echo done",
            "bash -c { make; make install; }",
            #"echo {"unterminated":1"#,
            #"echo prefix{"a":1}"#,
            #"echo {"a":1}suffix"#
        ] {
            #expect(CommandLineDisplayFormatter.format(command).text == command)
        }
    }

    @Test func optionsAreHighlightedButOnlyLongOptionsBreakLines() {
        let display = CommandLineDisplayFormatter.format("java -Xmx2g -Dmode=dev -jar app.jar -5 --server.port=8080")
        #expect(display.text == "java -Xmx2g -Dmode=dev -jar app.jar -5\n  --server.port=8080")
        let runs = display.lines.flatMap { $0 }
        #expect(runs.contains(.init(text: "-Dmode", role: .option)))
        #expect(runs.contains(.init(text: "--server.port", role: .option)))
        #expect(!runs.contains(.init(text: "-5", role: .option)))
    }

    @Test func emptyAndWhitespaceOnlyCommandsProduceOneEmptyLine() {
        #expect(CommandLineDisplayFormatter.format("").lines == [[]])
        #expect(CommandLineDisplayFormatter.format("   ").lines == [[]])
    }

    /// Unmatched brackets rescan the rest of the line; the shared budget
    /// keeps a hostile command from stalling the modal dialog.
    @Test func unmatchedBracketsStayWithinTheScanBudget() {
        let command = String(repeating: "[ ", count: 200_000) + #"{"a":1}"#
        let display = CommandLineDisplayFormatter.format(command)
        #expect(display.lines.count == 1)
        #expect(display.text.hasPrefix("[ [ [ "))
    }
}
