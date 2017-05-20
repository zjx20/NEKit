import Foundation
import QuartzCore

/// This adpater selects the fastest proxy automatically from a set of proxies.
public class SpeedAdapter: AdapterSocket, SocketDelegate {
    
    static var winnerHost:String?
    static let winnerRefresher:Int = {
        SpeedAdapter.refreshWinner()
        return 0
    }()
    static func refreshWinner() {
        QueueFactory.queue.asyncAfter(deadline: .now()+5) {
            SpeedAdapter.winnerHost = nil
            SpeedAdapter.refreshWinner()
        }
    }
    
    public var adapters: [(AdapterSocket, Int)]!
    var connectingCount = 0
    var pendingCount = 0
    
    var startTime:CFTimeInterval?

    override public func openSocketWith(session: ConnectSession) {
        
        _ = SpeedAdapter.winnerRefresher
        
        for (adapter, _) in adapters {
            adapter.observer = nil
        }

        super.openSocketWith(session: session)

        // FIXME: This is a temporary workaround for wechat which uses a wrong way to detect ipv6 by itself.
        if session.isIPv6() {
            _cancelled = true
            // Note `socket` is nil so `didDisconnectWith(socket:)` will never be called.
            didDisconnectWith(socket: self)
            return
        }
        
        var winner:AdapterSocket?
        if let winnerHost = SpeedAdapter.winnerHost {
            
            for (adapter, _) in adapters {
                if let ssAdapter = adapter as? ShadowsocksAdapter, ssAdapter.host == winnerHost {
                    winner = ssAdapter
                    break
                }
            }
        }
        
        self.startTime = CACurrentMediaTime()
        
        if let winner = winner {
            
            winner.delegate = self
            winner.openSocketWith(session: session)
            self.connectingCount += 1
        }
        else {
            pendingCount = adapters.count
            
            for (adapter, _) in adapters {
                
                adapter.delegate = self
                adapter.openSocketWith(session: session)
                self.connectingCount += 1
            }
        }
        
    }

    override public func disconnect(becauseOf error: Error? = nil) {
        super.disconnect(becauseOf: error)

        
        pendingCount = 0
        for (adapter, _) in adapters {
            adapter.delegate = nil
            if adapter.status != .invalid {
                adapter.disconnect(becauseOf: error)
            }
        }
    }

    override public func forceDisconnect(becauseOf error: Error? = nil) {
        super.forceDisconnect(becauseOf: error)
        
        pendingCount = 0
        for (adapter, _) in adapters {
            adapter.delegate = nil
            if adapter.status != .invalid {
                adapter.forceDisconnect(becauseOf: error)
            }
        }
    }

    public func didBecomeReadyToForwardWith(socket: SocketProtocol) {
        guard let adapterSocket = socket as? AdapterSocket else {
            return
        }

        // first we disconnect all other adapter now, and set delegate to nil
        for (adapter, _) in adapters {
            if adapter != adapterSocket {
                adapter.delegate = nil
                if adapter.status != .invalid {
                    adapter.forceDisconnect()
                }
            }
        }
        
        var latency:Double = 0
        
        if let startTime = self.startTime {
            latency = CACurrentMediaTime() - startTime
        }
        
        // We only have ss
        let ssAdapter = adapterSocket as! ShadowsocksAdapter
            
        if SpeedAdapter.winnerHost != ssAdapter.host {
            NotificationCenter.default.post(name: Notification.Name.init("DidFindFastestServer"), object: nil, userInfo: ["host":ssAdapter.host, "latency":latency])
            
            SpeedAdapter.winnerHost = ssAdapter.host
        }
        
        if latency >= 1.0 {
            // Need to find a better server
            SpeedAdapter.winnerHost = nil
        }

        delegate?.updateAdapterWith(newAdapter: adapterSocket)
        adapterSocket.observer = observer
        observer?.signal(.connected(adapterSocket))
        delegate?.didConnectWith(adapterSocket: adapterSocket)
        observer?.signal(.readyForForward(adapterSocket))
        delegate?.didBecomeReadyToForwardWith(socket: adapterSocket)
        delegate = nil
    }

    public func didDisconnectWith(socket: SocketProtocol) {
        connectingCount -= 1
        if connectingCount <= 0 && pendingCount == 0 {
            // failed to connect
            _status = .closed
            observer?.signal(.disconnected(self))
            delegate?.didDisconnectWith(socket: self)
        }
    }

    public func didConnectWith(adapterSocket socket: AdapterSocket) {}
    public func didWrite(data: Data?, by: SocketProtocol) {}
    public func didRead(data: Data, from: SocketProtocol) {}
    public func updateAdapterWith(newAdapter: AdapterSocket) {}
    public func didReceive(session: ConnectSession, from: ProxySocket) {}
}
