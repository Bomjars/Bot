/// XP needed per level. Level 1→2 costs `firstLevelRequirement`; each later
/// level costs the previous one plus the increment of the bracket it falls in.
public struct XPCurve {
    public let config: XPCurveConfig
    private let brackets: [XPBracket]

    public init(config: XPCurveConfig) {
        self.config = config
        brackets = config.brackets.sorted { $0.fromLevel < $1.fromLevel }
    }

    /// XP needed to advance from `level` to `level + 1`.
    public func requirement(forLevel level: Int) -> Float {
        var requirement = config.firstLevelRequirement
        guard level > 1 else { return requirement }
        for previous in 1..<level {
            requirement += increment(atLevel: previous)
        }
        return requirement
    }

    /// Total XP collected from level 1 to reach `level`.
    public func totalXP(toReach level: Int) -> Float {
        guard level > 1 else { return 0 }
        return (1..<level).reduce(0) { $0 + requirement(forLevel: $1) }
    }

    private func increment(atLevel level: Int) -> Float {
        brackets.last { $0.fromLevel <= level }?.increment ?? 0
    }
}
