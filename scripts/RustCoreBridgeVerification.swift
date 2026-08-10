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
      providers.contains(where: { $0["id"] as? String == "swift" }) else {
    fputs("Unexpected Rust Core LSP provider catalog: \(catalogResponse)\n", stderr)
    exit(1)
}

print("Rust Core LSP provider catalog passed: \(providers.count) providers")
