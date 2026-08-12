import Foundation

@_silgen_name("lithe_bridge_execute_json")
private func executeJSON(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("lithe_bridge_lsp_provider_catalog_json")
private func lspProviderCatalogJSON(_ workspaceRoot: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("lithe_bridge_free_string")
private func freeJSON(_ value: UnsafeMutablePointer<CChar>)

let request = #"{"id":"bridge-test","command":"core.ping","payload":{}}"#
let responsePointer = request.withCString { executeJSON($0) }
guard let responsePointer else {
    fputs("Rust Core bridge returned no response\n", stderr)
    exit(1)
}
defer { freeJSON(responsePointer) }

let response = String(cString: responsePointer)
guard let data = response.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["ok"] as? Bool == true,
      let payload = object["data"] as? [String: Any],
      payload["protocolVersion"] as? Int == 1 else {
    fputs("Unexpected Rust Core bridge response: \(response)\n", stderr)
    exit(1)
}

print("Rust Core bridge response passed: \(response)")

guard let catalogPointer = lspProviderCatalogJSON(nil) else {
    fputs("Rust Core LSP provider bridge returned no response\n", stderr)
    exit(1)
}
defer { freeJSON(catalogPointer) }

let catalogResponse = String(cString: catalogPointer)
guard let catalogData = catalogResponse.data(using: .utf8),
      let catalog = try? JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
      let providers = catalog["providers"] as? [[String: Any]],
      let swiftProvider = providers.first(where: { $0["id"] as? String == "swift" }),
      let swiftLaunch = swiftProvider["languageServerLaunch"] as? [String: Any],
      let swiftExecutables = swiftLaunch["executableNames"] as? [String],
      swiftExecutables.contains("sourcekit-lsp") else {
    fputs("Unexpected Rust Core LSP provider catalog: \(catalogResponse)\n", stderr)
    exit(1)
}

print("Rust Core LSP provider catalog passed: \(providers.count) providers")

let editRequest = """
{"id":"lsp-edit-test","command":"lsp.applyTextEdits","payload":{"text":"one 😀\\ntwo three\\n","edits":[{"range":{"start":{"line":0,"utf16Column":4},"end":{"line":0,"utf16Column":6}},"newText":"rocket"},{"range":{"start":{"line":1,"utf16Column":4},"end":{"line":1,"utf16Column":9}},"newText":"four"}]}}
"""
guard let editPointer = editRequest.withCString({ executeJSON($0) }) else {
    fputs("Rust Core LSP text edit bridge returned no response\n", stderr)
    exit(1)
}
defer { freeJSON(editPointer) }

let editResponse = String(cString: editPointer)
guard let editData = editResponse.data(using: .utf8),
      let editEnvelope = try? JSONSerialization.jsonObject(with: editData) as? [String: Any],
      let editPayload = editEnvelope["data"] as? [String: Any],
      editPayload["text"] as? String == "one rocket\ntwo four\n" else {
    fputs("Unexpected Rust Core LSP text edit response: \(editResponse)\n", stderr)
    exit(1)
}

let snippetRequest = """
{"id":"lsp-snippet-test","command":"lsp.plainSnippet","payload":{"value":"print(${1:value})$0"}}
"""
guard let snippetPointer = snippetRequest.withCString({ executeJSON($0) }) else {
    fputs("Rust Core LSP snippet bridge returned no response\n", stderr)
    exit(1)
}
defer { freeJSON(snippetPointer) }

let snippetResponse = String(cString: snippetPointer)
guard let snippetData = snippetResponse.data(using: .utf8),
      let snippetEnvelope = try? JSONSerialization.jsonObject(with: snippetData) as? [String: Any],
      let snippetPayload = snippetEnvelope["data"] as? [String: Any],
      snippetPayload["text"] as? String == "print(value)" else {
    fputs("Unexpected Rust Core LSP snippet response: \(snippetResponse)\n", stderr)
    exit(1)
}

print("Rust Core LSP text edit and snippet bridge passed")

let builtinCompletionRequest = """
{"id":"lsp-builtin-completion-test","command":"lsp.builtinCompletions","payload":{"filePath":"/tmp/main.swift","text":"struct RocketShip {}\\nlet value = Roc\\n","position":{"line":1,"utf16Column":15}}}
"""
guard let builtinCompletionPointer = builtinCompletionRequest.withCString({ executeJSON($0) }) else {
    fputs("Rust Core builtin completion bridge returned no response\n", stderr)
    exit(1)
}
defer { freeJSON(builtinCompletionPointer) }

let builtinCompletionResponse = String(cString: builtinCompletionPointer)
guard let builtinCompletionData = builtinCompletionResponse.data(using: .utf8),
      let builtinCompletionEnvelope = try? JSONSerialization.jsonObject(with: builtinCompletionData) as? [String: Any],
      let builtinCompletionPayload = builtinCompletionEnvelope["data"] as? [String: Any],
      let builtinCompletionItems = builtinCompletionPayload["items"] as? [[String: Any]],
      builtinCompletionItems.contains(where: { $0["label"] as? String == "RocketShip" }) else {
    fputs("Unexpected Rust Core builtin completion response: \(builtinCompletionResponse)\n", stderr)
    exit(1)
}

let builtinNavigationRequest = """
{"id":"lsp-builtin-navigation-test","command":"lsp.builtinNavigation","payload":{"filePath":"/tmp/main.swift","text":"let service = 1\\nprint(service)\\n","position":{"line":1,"utf16Column":8},"method":"textDocument/definition"}}
"""
guard let builtinNavigationPointer = builtinNavigationRequest.withCString({ executeJSON($0) }) else {
    fputs("Rust Core builtin navigation bridge returned no response\n", stderr)
    exit(1)
}
defer { freeJSON(builtinNavigationPointer) }

let builtinNavigationResponse = String(cString: builtinNavigationPointer)
guard let builtinNavigationData = builtinNavigationResponse.data(using: .utf8),
      let builtinNavigationEnvelope = try? JSONSerialization.jsonObject(with: builtinNavigationData) as? [String: Any],
      let builtinNavigationPayload = builtinNavigationEnvelope["data"] as? [String: Any],
      let builtinNavigationLocations = builtinNavigationPayload["locations"] as? [[String: Any]],
      builtinNavigationLocations.count == 1 else {
    fputs("Unexpected Rust Core builtin navigation response: \(builtinNavigationResponse)\n", stderr)
    exit(1)
}

print("Rust Core builtin LSP bridge passed")
