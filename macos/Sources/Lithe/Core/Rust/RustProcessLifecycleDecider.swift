import Foundation

struct RustProcessLifecycleDecider: ProcessLifecycleClassifying, Sendable {
    private let core: RustCoreBridge

    init(core: RustCoreBridge) {
        self.core = core
    }

    func resolve(
        context: ProcessLifecycleContext,
        settings: ProcessTerminationSettings,
        records: [ProcessLifecycleRecord]
    ) throws -> ProcessLifecyclePlan {
        try core.processLifecyclePlan(context: context, settings: settings, records: records).get()
    }

    func inventory(_ request: ProcessInventoryRequest) throws -> ProcessInventory {
        try core.executeResult(command: "processLifecycle.inventory", payload: request).get()
    }

    func settle(_ request: ProcessSettlementRequest) throws -> ProcessSettlement {
        try core.executeResult(command: "processLifecycle.settle", payload: request).get()
    }
}

extension RustCoreBridge {
    private struct ProcessLifecycleRequest: Encodable {
        let context: ProcessLifecycleContext
        let settings: ProcessTerminationSettings
        let records: [ProcessLifecycleRecord]
    }

    func processLifecyclePlan(
        context: ProcessLifecycleContext,
        settings: ProcessTerminationSettings,
        records: [ProcessLifecycleRecord]
    ) -> Result<ProcessLifecyclePlan, CoreCallError> {
        executeResult(
            command: "processLifecycle.resolve",
            payload: ProcessLifecycleRequest(context: context, settings: settings, records: records)
        )
    }
}
