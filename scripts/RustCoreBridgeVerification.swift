import Foundation

@_silgen_name("lithe_bridge_execute_json")
private func executeJSON(_ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

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
