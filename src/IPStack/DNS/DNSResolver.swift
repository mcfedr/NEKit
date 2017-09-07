import Foundation
import CocoaLumberjackSwift

public protocol DNSResolverProtocol: class {
    weak var delegate: DNSResolverDelegate? { get set }
    func resolve(session: DNSSession)
    func stop()
}

public protocol DNSResolverDelegate: class {
    func didReceive(rawResponse: Data)
}

open class UDPDNSResolver: DNSResolverProtocol, NWUDPSocketDelegate {
    var socket: NWUDPSocket?
    public weak var delegate: DNSResolverDelegate?
    public var didFail: (() -> (IPAddress, NEKit.Port)?)?
    
    let replacements: [String: String]?
    
    var address: IPAddress
    var port: Port

    public init(address: IPAddress, port: Port, replacements: [String: String]? = nil) {
        self.replacements = replacements
        self.address = address
        self.port = port
        self.createSocket()
    }

    private func createSocket() {
        socket?.disconnect()
        socket = NWUDPSocket(host: address.presentation, port: Int(port.value))
        socket?.delegate = self
    }
    
    public func resolve(session: DNSSession) {
        if let replacements = replacements {
            var needsBuild = false
            
            for (idx, query) in session.requestMessage.queries.enumerated() {
                for (origonal, replacement) in replacements {
                    if query.name == origonal {
                        let newQuery = DNSQuery(name: replacement, type: query.type, klass: query.klass, originalName: origonal)
                        session.requestMessage.queries[idx] = newQuery
                        
                        DDLogDebug("DNS Query: Replaced query for \(origonal) with \(replacement)")
                        
                        needsBuild = true
                    }
                }
            }
            
            if needsBuild {
                if session.requestMessage.buildMessage() {
                    DDLogDebug("DNS Query: Rewrote payload for request")
                } else {
                    DDLogDebug("DNS Query: Problem writing payload for request")
                }
            }
        }
        
        if socket == nil {
            createSocket()
        }
        if let requestPayload = session.requestMessage.payload {
            socket?.write(data: requestPayload)
        } else {
            DDLogError("Missing payload from DNS Message")
        }
    }

    public func stop() {
        socket?.disconnect()
    }

    public func didReceive(data: Data, from: NWUDPSocket) {
        delegate?.didReceive(rawResponse: data)
    }
    
    public func didCancel(socket: NWUDPSocket) {
        if let (address, port) = didFail?() {
            self.address = address
            self.port = port
            self.createSocket()
        }
    }
}
