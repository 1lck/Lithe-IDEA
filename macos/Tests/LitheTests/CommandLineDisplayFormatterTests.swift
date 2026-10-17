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

    /// An inline script must read exactly as it runs, so reported line breaks,
    /// indentation, tabs and repeated spaces survive and no break is re-indented.
    @Test func inlineScriptsKeepTheirLineBreaksAndSpaces() {
        let script = "python3 -c import time\nwhile True:\n    time.sleep(1)"
        let display = CommandLineDisplayFormatter.format(script)
        #expect(display.text == script)
        #expect(display.lines.count == 3)
        for command in ["printf a  b\tc", "run\n--flag value", "sh -c echo a\r\n  done"] {
            let text = CommandLineDisplayFormatter.format(command).text
            #expect(text.replacingOccurrences(of: "\r\n", with: "\n") == command.replacingOccurrences(of: "\r\n", with: "\n"))
        }
        #expect(CommandLineDisplayFormatter.format("  npm run dev \n").text == "npm run dev")
    }

    /// Indenting deep and wide JSON would multiply its size; past the layout
    /// budget it is shown as reported instead.
    @Test func jsonPastTheLayoutBudgetStaysAsReported() {
        let json = String(repeating: "[", count: 400)
            + Array(repeating: "0", count: 50_000).joined(separator: ",")
            + String(repeating: "]", count: 400)
        let display = CommandLineDisplayFormatter.format("tool --settings " + json)
        #expect(display.text == "tool\n  --settings " + json)
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
