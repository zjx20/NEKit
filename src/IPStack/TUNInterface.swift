import Foundation
import NetworkExtension
import CocoaLumberjackSwift

/// TUN interface provide a scheme to register a set of IP Stacks (implementing `IPStackProtocol`) to process IP packets from a virtual TUN interface.
open class TUNInterface {
    fileprivate weak var packetFlow: NEPacketTunnelFlow?
    fileprivate var stacks: [IPStackProtocol] = []
    
    /**
     Initialize TUN interface with a packet flow.
     
     - parameter packetFlow: The packet flow to work with.
     */
    public init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
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
    
    func checkMemory() -> UInt64 {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            DDLogDebug("Memory used in bytes: \(taskInfo.resident_size)")
            return taskInfo.resident_size
        }
        else {
            DDLogDebug("Error with task_info(): " +
                (String(cString: mach_error_string(kerr), encoding: String.Encoding.ascii) ?? "unknown error"))
            return 0
        }
    }
    
    fileprivate func readPackets() {
        _ = self.checkMemory()
        
        packetFlow?.readPackets { packets, versions in
            QueueFactory.getQueue().async {
                for (i, packet) in packets.enumerated() {
                    for stack in self.stacks {
                        if stack.input(packet: packet, version: versions[i]) {
                            break
                        }
                    }
                }
            }
            
            self.readPackets()
        }
    }
    
    fileprivate func generateOutputBlock() -> ([Data], [NSNumber]) -> Void {
        return { [weak self] packets, versions in
            self?.packetFlow?.writePackets(packets, withProtocols: versions)
        }
    }
}
