import Foundation

/// 2D vector used throughout the simulation (world units are SpriteKit points).
public typealias Vec2 = SIMD2<Float>

extension SIMD2 where Scalar == Float {
    @inlinable public var lengthSquared: Float { x * x + y * y }

    @inlinable public var length: Float { lengthSquared.squareRoot() }

    @inlinable public func normalized() -> SIMD2<Float> {
        let len = length
        return len > 0 ? self / len : .zero
    }

    @inlinable public static func unit(angle: Float) -> SIMD2<Float> {
        SIMD2(cos(angle), sin(angle))
    }
}

/// Deterministic, seedable RNG so runs and tests are reproducible.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
