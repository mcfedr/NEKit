import Foundation
import NetworkExtension
import CocoaLumberjackSwift

/// TUN interface provide a scheme to register a set of IP Stacks (implementing `IPStackProtocol`) to process IP packets from a virtual TUN interface.
open class TUNInterface {
    
    static var globalPendingReadDataSize:Int64 = 0
    
    static func updateGlobalPendingReadDataSize(_ delta:Int64) {
        let oldSize = TUNInterface.globalPendingReadDataSize
        TUNInterface.globalPendingReadDataSize += delta
        let newSize = TUNInterface.globalPendingReadDataSize
        
        let kMaxGlobalPendingReadDataSize:Int64 = 1*1024*1024
        if oldSize <= kMaxGlobalPendingReadDataSize && newSize > kMaxGlobalPendingReadDataSize {
            NotificationCenter.default.post(name: Notification.Name.init("NEKit.TUNTCPSocket.globalPendingReadDataSize.WaterLevelOK"), object: false)
        }
        else if oldSize > kMaxGlobalPendingReadDataSize && newSize <= kMaxGlobalPendingReadDataSize {
            NotificationCenter.default.post(name: Notification.Name.init("NEKit.TUNTCPSocket.globalPendingReadDataSize.WaterLevelOK"), object: true)
        }
    }
    
    private var tokenForWaterLevel:NSObjectProtocol?
    private var isWaterLevelOK = true
    
    fileprivate weak var packetFlow: NEPacketTunnelFlow?
    fileprivate var stacks: [IPStackProtocol] = []
    
    
    /**
     Initialize TUN interface with a packet flow.
     
     - parameter packetFlow: The packet flow to work with.
     */
    public init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
        self.tokenForWaterLevel = NotificationCenter.default.addObserver(forName: Notification.Name.init("NEKit.TUNTCPSocket.globalPendingReadDataSize.WaterLevelOK"), object: nil, queue: nil) { [weak self] (noti) in
            if let isWaterLevelOK = noti.object as? NSNumber, isWaterLevelOK.boolValue {
                self?.isWaterLevelOK = true
                self?.readPackets()
            }
            else {
                self?.isWaterLevelOK = false
            }
        }
    }
    
    deinit {
        if let tokenForWaterLevel = tokenForWaterLevel {
            NotificationCenter.default.removeObserver(tokenForWaterLevel)
        }
    }
    
    /**
     Start processing packets, this should be called after registering all IP stacks.
     
     A stopped interface should never start again. Create a new interface instead.
     */
    open func start() {
        QueueFactory.executeOnQueueSynchronizedly {
            for stack in self.stacks {
                stack.start()
            }
            
            self.readPackets()
        }
    }
    
    /**
     Stop processing packets, this should be called before releasing the interface.
     */
    open func stop() {
        QueueFactory.executeOnQueueSynchronizedly {
            self.packetFlow = nil
            
            for stack in self.stacks {
                stack.stop()
            }
            self.stacks = []
        }
    }
    
    /**
     Register a new IP stack.
     
     When a packet is read from TUN interface (the packet flow), it is passed into each IP stack according to the registration order until one of them takes it in.
     
     - parameter stack: The IP stack to append to the stack list.
     */
    open func register(stack: IPStackProtocol) {
        QueueFactory.executeOnQueueSynchronizedly {
            stack.outputFunc = self.generateOutputBlock()
            self.stacks.append(stack)
        }
    }
    
    fileprivate func readPackets() {
        
        if self.isWaterLevelOK {
            packetFlow?.readPackets { packets, versions in
                QueueFactory.getQueue().async {
                    
                    for (i, packet) in packets.enumerated() {
                        for stack in self.stacks {
                            if stack.input(packet: packet, version: versions[i]) {
                                break
                            }
                        }
                    }
                    
                    if self.isWaterLevelOK {
                        self.readPackets()
                    }
                }
            }
        }
    }
    
    fileprivate func generateOutputBlock() -> ([Data], [NSNumber]) -> Void {
        return { [weak self] packets, versions in
            autoreleasepool {
                self?.packetFlow?.writePackets(packets, withProtocols: versions)
            }
        }
    }
}
