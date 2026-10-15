import SpriteKit

/// Pool of sprites that stay in the tree: each frame `begin()`, take nodes with `next()`, then `end()` hides the
/// ones not used this frame. No allocation after warm-up, no add/remove churn.
final class SpritePool {
    let parent: SKNode
    private(set) var nodes: [SKSpriteNode] = []
    private(set) var used = 0
    private var shownLastFrame = 0
    let capacity: Int
    private let configure: (SKSpriteNode) -> Void

    init(parent: SKNode, capacity: Int, configure: @escaping (SKSpriteNode) -> Void) {
        self.parent = parent
        self.capacity = capacity
        self.configure = configure
    }

    func begin() { used = 0 }

    /// Next free sprite (nil when the pool is exhausted).
    func next() -> SKSpriteNode? {
        if used >= capacity { return nil }
        if used == nodes.count {
            let n = SKSpriteNode(texture: nil)
            configure(n)
            parent.addChild(n)
            nodes.append(n)
        }
        let n = nodes[used]
        used += 1
        if n.isHidden { n.isHidden = false }
        return n
    }

    func end() {
        if used < shownLastFrame {
            for k in used..<shownLastFrame { nodes[k].isHidden = true }
        }
        shownLastFrame = used
    }

    func hideAll() { begin(); end() }
}

/// Fixed ring of sprites for long-lived things (corpses, decals): the oldest is reused when full.
final class SpriteRing {
    let parent: SKNode
    let capacity: Int
    private(set) var nodes: [SKSpriteNode] = []
    private var head = 0
    private let configure: (SKSpriteNode) -> Void

    init(parent: SKNode, capacity: Int, configure: @escaping (SKSpriteNode) -> Void) {
        self.parent = parent
        self.capacity = capacity
        self.configure = configure
    }

    func next() -> SKSpriteNode {
        if nodes.count < capacity {
            let n = SKSpriteNode(texture: nil)
            configure(n)
            parent.addChild(n)
            nodes.append(n)
            return n
        }
        let n = nodes[head]
        head = (head + 1) % capacity
        n.isHidden = false
        return n
    }

    var count: Int { nodes.count }

    func clear() {
        for n in nodes { n.removeFromParent() }
        nodes.removeAll()
        head = 0
    }
}
