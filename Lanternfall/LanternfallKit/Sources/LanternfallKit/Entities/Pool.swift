public protocol Poolable {
    var isActive: Bool { get set }
}

/// Fixed-capacity object pool. Slots are reused, never reallocated, so the
/// renderer can keep one node per slot and just show/hide it.
public struct Pool<Element: Poolable> {
    public internal(set) var items: [Element]
    private var freeIndices: [Int]
    public private(set) var activeCount = 0

    public init(capacity: Int, placeholder: Element) {
        var inactive = placeholder
        inactive.isActive = false
        items = Array(repeating: inactive, count: capacity)
        // Reversed so slot 0 is handed out first.
        freeIndices = Array((0..<capacity).reversed())
    }

    public var capacity: Int { items.count }
    public var isFull: Bool { freeIndices.isEmpty }
    public var availableCount: Int { freeIndices.count }

    /// Stores `element` in a free slot and returns its index, or nil when full.
    @discardableResult
    public mutating func spawn(_ element: Element) -> Int? {
        guard let index = freeIndices.popLast() else { return nil }
        var active = element
        active.isActive = true
        items[index] = active
        activeCount += 1
        return index
    }

    public mutating func despawn(at index: Int) {
        guard items[index].isActive else { return }
        items[index].isActive = false
        freeIndices.append(index)
        activeCount -= 1
    }
}
