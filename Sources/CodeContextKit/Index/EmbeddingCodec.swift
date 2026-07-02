import Foundation

/// Encodes and decodes embedding vectors as little-endian `Float32` blobs
/// for storage in `ts_chunks.embedding` (see plan.md "The index").
///
/// A fixed little-endian layout (rather than the host's native byte order)
/// keeps `kit.db` portable across architectures, matching the Rust store's
/// blob format.
public enum EmbeddingCodec {
    /// Encodes `vector` into a little-endian `Float32` blob, 4 bytes per
    /// element, in order.
    public static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<Float>.size)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Decodes a little-endian `Float32` blob back into a vector of
    /// `Float`, the exact inverse of `encode(_:)`.
    ///
    /// - Precondition: `data.count` is a multiple of 4 (the size of one
    ///   `Float32`).
    public static func decode(_ data: Data) -> [Float] {
        let floatSize = MemoryLayout<Float>.size
        precondition(
            data.count.isMultiple(of: floatSize),
            "EmbeddingCodec: byte count \(data.count) is not a multiple of \(floatSize)"
        )
        let count = data.count / floatSize
        return data.withUnsafeBytes { rawBuffer in
            (0..<count).map { index in
                let bits = rawBuffer.loadUnaligned(fromByteOffset: index * floatSize, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }
}
