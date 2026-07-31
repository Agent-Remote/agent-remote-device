import Foundation

final class ErrorReply: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((NSError?) -> Void)?

    init(_ reply: @escaping (NSError?) -> Void) {
        self.reply = reply
    }

    func resolve(_ error: NSError?) {
        lock.lock()
        guard let reply else {
            lock.unlock()
            return
        }
        self.reply = nil
        lock.unlock()
        reply(error)
    }
}

final class DataReply: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((NSData?, NSError?) -> Void)?

    init(_ reply: @escaping (NSData?, NSError?) -> Void) {
        self.reply = reply
    }

    func resolve(data: NSData?, error: NSError?) {
        lock.lock()
        guard let reply else {
            lock.unlock()
            return
        }
        self.reply = nil
        lock.unlock()
        reply(data, error)
    }
}
