/// Converts variable frame times into a whole number of fixed simulation steps.
public struct FixedTimestepClock {
    public let stepDuration: Double
    public let maxSteps: Int
    /// Fraction of a step that may be borrowed from the next frame.
    public let snapTolerance: Double

    private var lastTime: Double?
    public private(set) var accumulator: Double = 0

    public init(stepDuration: Double, maxSteps: Int, snapTolerance: Double) {
        self.stepDuration = stepDuration
        self.maxSteps = maxSteps
        self.snapTolerance = snapTolerance
    }

    public init(config: SimulationConfig) {
        self.init(
            stepDuration: config.fixedTimestep,
            maxSteps: config.maxStepsPerFrame,
            snapTolerance: config.timestepSnapTolerance
        )
    }

    /// Returns how many steps to run for a frame at `time` (seconds).
    /// The first call only records the time. After a long hitch the backlog
    /// is dropped rather than replayed.
    public mutating func advance(to time: Double) -> Int {
        guard let last = lastTime else {
            lastTime = time
            return 0
        }
        lastTime = time
        accumulator += max(0, time - last)

        let steps = Int(accumulator / stepDuration + snapTolerance)
        if steps > maxSteps {
            accumulator = 0
            return maxSteps
        }
        accumulator -= Double(steps) * stepDuration
        return steps
    }

    /// Forget the last frame time, e.g. when returning from background.
    public mutating func reset() {
        lastTime = nil
        accumulator = 0
    }
}
