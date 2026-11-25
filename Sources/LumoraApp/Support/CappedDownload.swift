import Foundation

/// Downloads that can't exceed a size limit: a declared length over the limit is refused before
/// reading, and reading stops as soon as the running total passes it, so a server that lies
/// about (or omits) the length still can't fill memory.
enum CappedDownload {
    enum Failure: Error {
        case tooLarge
        case http(Int)
        case network(String)
    }

    static func data(for request: URLRequest, maxBytes: Int) async -> Result<Data, Failure> {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            bytes.task.cancel()
            return .failure(.http(http.statusCode))
        }
        if response.expectedContentLength > Int64(maxBytes) {
            bytes.task.cancel()
            return .failure(.tooLarge)
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        var chunk = [UInt8]()
        chunk.reserveCapacity(64 * 1024)
        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    data.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                    if data.count > maxBytes {
                        bytes.task.cancel()
                        return .failure(.tooLarge)
                    }
                }
            }
        } catch {
            return .failure(.network(error.localizedDescription))
        }
        data.append(contentsOf: chunk)
        return data.count > maxBytes ? .failure(.tooLarge) : .success(data)
    }
}
