import Foundation
import NetworkExtension
import CocoaLumberjackSwift
import KVOController

/// The TCP socket build upon `NWTCPConnection`.
///
/// - warning: This class is not thread-safe.
public class NWTCPSocket: NSObject, RawTCPSocketProtocol {
    private static var kKVOConnectionStatusContext = 0
    private static var kKVOConnectionHasBetterPath = 0
    
    private var connection: NWTCPConnection?
    private var betterConnection: NWTCPConnection?
    
    private var writePending = false
    private var closeAfterWriting = false
    private var cancelled = false
    
    private var scanner: StreamScanner!
    private var scanning: Bool = false
    private var readDataPrefix: Data?
    
    // MARK: RawTCPSocketProtocol implementation
    
    /// The `RawTCPSocketDelegate` instance.
    weak open var delegate: RawTCPSocketDelegate?
    
    /// Only for debug purpose.
    weak public var session: ConnectSession?
    
    /// If the socket is connected.
    public var isConnected: Bool {
        return connection != nil && connection!.state == .connected
    }
    
    /// The source address.
    ///
    /// - note: Always returns `nil`.
    public var sourceIPAddress: IPAddress? {
        return nil
    }
    
    /// The source port.
    ///
    /// - note: Always returns `nil`.
    public var sourcePort: Port? {
        return nil
    }
    
    /// The destination address.
    ///
    /// - note: Always returns `nil`.
    public var destinationIPAddress: IPAddress? {
        return nil
    }
    
    /// The destination port.
    ///
    /// - note: Always returns `nil`.
    public var destinationPort: Port? {
        return nil
    }
    
    /**
     Connect to remote host.
     
     - parameter host:        Remote host.
     - parameter port:        Remote port.
     - parameter enableTLS:   Should TLS be enabled.
     - parameter tlsSettings: The settings of TLS.
     
     - throws: Never throws.
     */
    public func connectTo(host: String, port: Int, enableTLS: Bool, tlsSettings: [AnyHashable: Any]?) throws {
        let endpoint = NWHostEndpoint(hostname: host, port: "\(port)")
        let tlsParameters = NWTLSParameters()
        if let tlsSettings = tlsSettings as? [String: AnyObject] {
            tlsParameters.setValuesForKeys(tlsSettings)
        }
        
        guard let connection = RawSocketFactory.TunnelProvider?.createTCPConnection(to: endpoint, enableTLS: enableTLS, tlsParameters: tlsParameters, delegate: nil) else {
            // This should only happen when the extension is already stopped and `RawSocketFactory.TunnelProvider` is set to `nil`.
            return
        }
        
        self.connection = connection
        self.kvoController.observe(connection, keyPath: "state", options: [.initial, .new], context: &NWTCPSocket.kKVOConnectionStatusContext)
        self.kvoController.observe(connection, keyPath: "hasBetterPath", options: [.new], context: &NWTCPSocket.kKVOConnectionHasBetterPath)
    }
    
    /**
     Disconnect the socket.
     
     The socket will disconnect elegantly after any queued writing data are successfully sent.
     */
    public func disconnect() {
        cancelled = true
        
        if connection == nil  || connection!.state == .cancelled {
            delegate?.didDisconnectWith(socket: self)
        } else {
            closeAfterWriting = true
            checkStatus()
        }
    }
    
    /**
     Disconnect the socket immediately.
     */
    public func forceDisconnect() {
        cancelled = true
        
        if connection == nil  || connection!.state == .cancelled {
            delegate?.didDisconnectWith(socket: self)
        } else {
            cancel()
        }
    }
    
    /**
     Send data to remote.
     
     - parameter data: Data to send.
     - warning: This should only be called after the last write is finished, i.e., `delegate?.didWriteData()` is called.
     */
    public func write(data: Data) {
        guard !cancelled else {
            return
        }
        
        guard data.count > 0 else {
            QueueFactory.getQueue().async {
                self.delegate?.didWrite(data: data, by: self)
            }
            return
        }
        
        send(data: data)
    }
    
    /**
     Read data from the socket.
     
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    public func readData() {
        guard !cancelled else {
            return
        }
        
        if let connection = self.connection {
            
            let startTime = CACurrentMediaTime()
            
            connection.readMinimumLength(1, maximumLength: Opt.MAXNWTCPSocketReadDataSize) { data, error in
                guard error == nil else {
                    
                    DDLogError("NWTCPSocket<\(String(describing: self.session?.host)):\(String(describing: self.session?.port))> read failed: \(String(describing: error))")
                    self.queueCall {
                        self.disconnect()
                    }
                    return
                }
                
                let duration = CACurrentMediaTime() - startTime
                if let host = (self.connection?.endpoint as? NWHostEndpoint)?.hostname, let bytes = data?.count {
                    NotificationCenter.default.post(name: Notification.Name.init("DataDidDownload"), object: nil, userInfo: ["host":host,
                                                                                                                             "bytes":bytes,
                                                                                                                             "duration":duration])
                }
                
                
                self.readCallback(data: data)
            }
        }
    }
    
    /**
     Read specific length of data from the socket.
     
     - parameter length: The length of the data to read.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    public func readDataTo(length: Int) {
        guard !cancelled else {
            return
        }
        
        if let connection = self.connection {
            
            let startTime = CACurrentMediaTime()
            
            connection.readLength(length) { data, error in
                guard error == nil else {
                    DDLogError("NWTCPSocket<\(String(describing: self.session?.host)):\(String(describing: self.session?.port))> read failed: \(String(describing: error))")
                    self.queueCall {
                        self.disconnect()
                    }
                    return
                }
                
                let duration = CACurrentMediaTime() - startTime
                if let host = (self.connection?.endpoint as? NWHostEndpoint)?.hostname, let bytes = data?.count {
                    NotificationCenter.default.post(name: Notification.Name.init("DataDidDownload"), object: nil, userInfo: ["host":host,
                                                                                                                             "bytes":bytes,
                                                                                                                             "duration":duration])
                }
                
                self.readCallback(data: data)
            }
        }
    }
    
    /**
     Read data until a specific pattern (including the pattern).
     
     - parameter data: The pattern.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    public func readDataTo(data: Data) {
        readDataTo(data: data, maxLength: 0)
    }
    
    // Actually, this method is available as `- (void)readToPattern:(id)arg1 maximumLength:(unsigned int)arg2 completionHandler:(id /* block */)arg3;`
    // which is sadly not available in public header for some reason I don't know.
    // I don't want to do it myself since This method is not trival to implement and I don't like reinventing the wheel.
    // Here is only the most naive version, which may not be the optimal if using with large data blocks.
    /**
     Read data until a specific pattern (including the pattern).
     
     - parameter data: The pattern.
     - parameter maxLength: The max length of data to scan for the pattern.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    public func readDataTo(data: Data, maxLength: Int) {
        guard !cancelled else {
            return
        }
        
        var maxLength = maxLength
        if maxLength == 0 {
            maxLength = Opt.MAXNWTCPScanLength
        }
        scanner = StreamScanner(pattern: data, maximumLength: maxLength)
        scanning = true
        readData()
    }
    
    private func queueCall(_ block: @escaping () -> Void) {
        QueueFactory.getQueue().async(execute: block)
    }
    
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        QueueFactory.getQueue().async {[weak self] in
            
            if let strongSelf = self, let changedConnection = object as? NWTCPConnection {
                
                if context == &NWTCPSocket.kKVOConnectionStatusContext && keyPath == "state" {
                    
                    if changedConnection == strongSelf.connection {
                        // The current connection
                        switch changedConnection.state {
                            
                        case .connected:
                            strongSelf.delegate?.didConnectWith(socket: strongSelf)
                        case .disconnected:
                            strongSelf.cancelled = true
                            strongSelf.cancel()
                        case .cancelled:
                            strongSelf.cancelled = true
                            
                            let delegate = strongSelf.delegate
                            strongSelf.delegate = nil
                            delegate?.didDisconnectWith(socket: strongSelf)
                            
                        default:
                            break
                        }
                    }
                    else if changedConnection == strongSelf.betterConnection {
                        // The upgraded connection
                        switch changedConnection.state {
                        case .connected:
                            strongSelf.kvoController.unobserve(strongSelf.connection)
                            strongSelf.connection?.cancel()
                            strongSelf.connection = changedConnection
                            strongSelf.betterConnection = nil
                            
                        case .disconnected, .cancelled:
                            strongSelf.kvoController.unobserve(strongSelf.betterConnection)
                            strongSelf.betterConnection = nil
                            
                        default:
                            break
                        }
                    }
                }
                else if context == &NWTCPSocket.kKVOConnectionHasBetterPath && keyPath == "hasBetterPath" {
                    
                    if changedConnection.hasBetterPath {
                        
                        if let existedBetterConnection = strongSelf.betterConnection {
                            strongSelf.kvoController.unobserve(existedBetterConnection)
                            existedBetterConnection.cancel()
                        }
                        
                        strongSelf.betterConnection = NWTCPConnection(upgradeFor: changedConnection)
                        
                        strongSelf.kvoController.observe(strongSelf.betterConnection, keyPath: "state", options: [.initial, .new], context: &NWTCPSocket.kKVOConnectionStatusContext)
                        strongSelf.kvoController.observe(strongSelf.betterConnection, keyPath: "hasBetterPath", options: [.new], context: &NWTCPSocket.kKVOConnectionHasBetterPath)
                    }
                }
            }
        }
    }
    
    private func readCallback(data: Data?) {
        guard !cancelled else {
            return
        }
        
        queueCall {
            guard let data = self.consumeReadData(data) else {
                // remote read is closed, but this is okay, nothing need to be done, if this socket is read again, then error occurs.
                return
            }
            
            if self.scanning {
                guard let (match, rest) = self.scanner.addAndScan(data) else {
                    self.readData()
                    return
                }
                
                self.scanner = nil
                self.scanning = false
                
                guard let matchData = match else {
                    // do not find match in the given length, stop now
                    return
                }
                
                self.readDataPrefix = rest
                self.delegate?.didRead(data: matchData, from: self)
            } else {
                self.delegate?.didRead(data: data, from: self)
            }
        }
    }
    
    private func send(data: Data) {
        writePending = true
        if let connection = self.connection {
            
            let startTime = CACurrentMediaTime()
            
            connection.write(data) { error in
                self.queueCall {
                    self.writePending = false
                    
                    guard error == nil else {
                        DDLogError("NWTCPSocket<\(String(describing: self.session?.host)):\(String(describing: self.session?.port))> write failed: \(String(describing: error))")
                        self.disconnect()
                        return
                    }
                    
                    let duration = CACurrentMediaTime() - startTime
                    if let host = (self.connection?.endpoint as? NWHostEndpoint)?.hostname {
                        NotificationCenter.default.post(name: Notification.Name.init("DataDidUpload"), object: nil, userInfo: ["host":host,
                                                                                                                                 "bytes":data.count,
                                                                                                                                 "duration":duration])
                    }
                    
                    self.delegate?.didWrite(data: data, by: self)
                    self.checkStatus()
                }
            }
        }
        
    }
    
    private func consumeReadData(_ data: Data?) -> Data? {
        defer {
            readDataPrefix = nil
        }
        
        if readDataPrefix == nil {
            return data
        }
        
        if data == nil {
            return readDataPrefix
        }
        
        var wholeData = readDataPrefix!
        wholeData.append(data!)
        return wholeData
    }
    
    private func cancel() {
        connection?.cancel()
    }
    
    private func checkStatus() {
        if closeAfterWriting && !writePending {
            cancel()
        }
    }
}
