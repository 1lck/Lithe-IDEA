import Foundation
import LitheCoreContracts

public protocol DebugSteppingFilterPersisting: Sendable {
    func loadSteppingFilters(adapterID: String) throws -> DebugSteppingFilters?
    func saveSteppingFilters(_ filters: DebugSteppingFilters, adapterID: String) throws
}
