import Foundation

class HTTPStreamScanner {
    enum ReadAction {
        case readHeader, readContent, stop
    }
    
    enum Result {
        case header(HTTPHeader), content(Data)
    }
    
    enum HTTPStreamScannerError: Error {
        case contentIsTooLong, scannerIsStopped, unsupportedStreamType
    }
    
    var nextAction: ReadAction = .readHeader
    
    var currentHeader: HTTPHeader!
    
    var isConnect: Bool = false
    
    func input(_ data: Data) throws -> Result {
        
        switch nextAction {
            
        case .readHeader:
            let header: HTTPHeader
            do {
                header = try HTTPHeader(headerData: data)
            } catch let error {
                nextAction = .stop
                throw error
            }
            
            if header.isConnect {
                isConnect = true
                
            } else {
                isConnect = false
            }
            
            currentHeader = header
            
            nextAction = .readContent
            
            return .header(header)
        case .readContent:
            
            return .content(data)
        case .stop:
            throw HTTPStreamScannerError.scannerIsStopped
        }
    }
}
