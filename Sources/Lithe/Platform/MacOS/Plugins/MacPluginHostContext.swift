import LitheModuleAPI

@MainActor
final class MacPluginHostServiceRegistry: PluginHostServiceResolving {
    private var services: [PluginHostServiceID: AnyObject] = [:]

    func register(_ service: AnyObject, for id: PluginHostServiceID) {
        precondition(services[id] == nil, "Plugin host service \(id) is already registered.")
        services[id] = service
    }

    func service(_ id: PluginHostServiceID) -> AnyObject? {
        services[id]
    }
}
