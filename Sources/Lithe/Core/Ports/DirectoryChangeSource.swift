import Foundation

protocol DirectoryChangeSource: AnyObject {
    func start()
    func stop()
}
