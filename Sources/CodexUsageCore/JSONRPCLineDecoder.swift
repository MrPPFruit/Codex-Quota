import Foundation

public struct JSONRPCLineDecoder: Sendable {
    private var buffer = Data()
    private let maximumFrameBytes: Int

    public init(maximumFrameBytes: Int = 1_048_576) {
        precondition(maximumFrameBytes > 0)
        self.maximumFrameBytes = maximumFrameBytes
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard line.count <= maximumFrameBytes else {
                reset()
                throw AppServerClientError.frameTooLarge
            }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        guard buffer.count <= maximumFrameBytes else {
            reset()
            throw AppServerClientError.frameTooLarge
        }
        return lines
    }

    public mutating func reset() { buffer.removeAll(keepingCapacity: false) }
}
