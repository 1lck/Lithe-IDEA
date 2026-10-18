import Testing
@testable import Lithe

/// Pure presentation regressions: no processes, network, clocks, or persistent state.
struct McpServerSummaryTests {
    @Test
    func commandSummaryOmitsAllArgumentsAndEnvironment() {
        let row = makeRow(McpServerDefinition(
            name: "example",
            command: "/opt/private-path-secret/bin/node",
            args: ["server.js", "--token", "argument-token-secret", "https://user:argument-password@example.com"],
            env: [McpKeyValue(key: "TOKEN", value: "environment-secret")]
        ))

        #expect(row.summary == "node")
        #expect(row.definition.args.contains("argument-token-secret"))
    }

    @Test
    func inlineCommandSummaryShowsOnlyExecutableName() {
        let row = makeRow(McpServerDefinition(
            name: "example",
            command: "/bin/sh -c 'TOKEN=inline-secret node server.js'"
        ))

        #expect(row.summary == "sh")
    }

    @Test(arguments: [
        "TOKEN=assignment-secret node server.js",
        "https://user:command-secret@example.com/mcp",
        "node;credential-secret",
        "print('script-secret')",
        #""/private/path-secret/server name""#,
        "/",
        "..",
        ""
    ])
    func unsafeCommandsFallBackWithoutEchoingInput(command: String) {
        let row = makeRow(McpServerDefinition(name: "example", command: command))

        #expect(row.summary == "Command")
    }

    @Test
    func missingCommandFallsBackWithoutShowingArguments() {
        let row = makeRow(McpServerDefinition(name: "example", args: ["argument-only-secret"]))

        #expect(row.summary == "Command")
    }

    @Test(arguments: [McpTransport.http, .sse])
    func urlSummaryRemovesUserInfoQueryFragmentAndHeaders(transport: McpTransport) {
        let row = makeRow(McpServerDefinition(
            name: "example",
            transport: transport,
            url: "https://username-secret:password-secret@example.com:8443/mcp?token=query-secret#fragment-secret",
            headers: [McpKeyValue(key: "Authorization", value: "Bearer header-secret")]
        ))

        #expect(row.summary == "https://example.com:8443/mcp")
        #expect(row.definition.url?.contains("password-secret") == true)
    }

    @Test(arguments: [McpTransport.http, .sse])
    func encodedUserInfoAndSecretsAreAlsoRemoved(transport: McpTransport) {
        let row = makeRow(McpServerDefinition(
            name: "example",
            transport: transport,
            url: "http://user%40secret:pass%3Asecret@localhost:8080/mcp?token=query%2Dsecret#fragment%2Dsecret"
        ))

        #expect(row.summary == "http://localhost:8080/mcp")
    }

    @Test(arguments: [
        "",
        "not a URL credential-secret",
        "/relative/path?token=relative-secret",
        "https:///mcp?token=missing-host-secret",
        "https://[invalid-host/?token=invalid-secret",
        "https://example.com:invalid/?token=invalid-port-secret",
        "https://example.com/mcp?token=space secret",
        "https://example.com/%?token=malformed-escape-secret",
        "https://example.com/mcp\n?token=newline-secret",
        "file:///private/token-secret",
        "mailto:user-secret@example.com"
    ])
    func invalidURLsFallBackToTransportWithoutEchoingInput(url: String) {
        for transport in [McpTransport.http, .sse] {
            let row = makeRow(McpServerDefinition(name: "example", transport: transport, url: url))

            #expect(row.summary == transport.title)
        }
    }

    @Test(arguments: [McpTransport.http, .sse])
    func missingURLFallsBackToTransport(transport: McpTransport) {
        let row = makeRow(McpServerDefinition(name: "example", transport: transport))

        #expect(row.summary == transport.title)
    }

    private func makeRow(_ definition: McpServerDefinition) -> McpServerRow {
        McpServerRow(id: "summary-test", definition: definition, sources: [], hasDefinitionConflict: false)
    }
}
