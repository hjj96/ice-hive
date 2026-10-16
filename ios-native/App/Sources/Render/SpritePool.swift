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

    /// Nodes created by every pool and ring so far (hitch attribution: growth during play).
    static var created = 0

    func begin() { used = 0 }

    /// Create hidden nodes up front (behind the loading cover), so a bigger swarm later never allocates mid-game.
    func reserve(_ n: Int) {
        let target = min(n, capacity)
        while nodes.count < target {
            let s = SKSpriteNode(texture: nil)
            configure(s)
            s.isHidden = true
            parent.addChild(s)
            nodes.append(s)
            SpritePool.created += 1
        }
    }

    /// Next free sprite (nil when the pool is exhausted).
    func next() -> SKSpriteNode? {
        if used >= capacity { return nil }
        if used == nodes.count {
            let n = SKSpriteNode(texture: nil)
            configure(n)
            parent.addChild(n)
            nodes.append(n)
            SpritePool.created += 1
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
    /// Sprites handed out since the last clear (at most `capacity`).
    private(set) var live = 0
    private let configure: (SKSpriteNode) -> Void

    init(parent: SKNode, capacity: Int, configure: @escaping (SKSpriteNode) -> Void) {
        self.parent = parent
        self.capacity = capacity
        self.configure = configure
    }

    func next() -> SKSpriteNode {
        if live < capacity { live += 1 }
        if head == nodes.count && nodes.count < capacity {
            let n = SKSpriteNode(texture: nil)
            configure(n)
            parent.addChild(n)
            nodes.append(n)
            SpritePool.created += 1
            head = (head + 1) % capacity
            return n
        }
        let n = nodes[head]
        head = (head + 1) % capacity
        n.isHidden = false
        return n
    }

    /// Create every node of the ring up front (hidden), so filling it during play never allocates.
    func reserve() {
        while nodes.count < capacity {
            let n = SKSpriteNode(texture: nil)
            configure(n)
            n.isHidden = true
            parent.addChild(n)
            nodes.append(n)
            SpritePool.created += 1
        }
    }

    var count: Int { live }

    /// Hide everything and start over from the first node (the nodes stay in the tree for reuse).
    func clear() {
        for n in nodes { n.isHidden = true }
        live = 0
        head = 0
    }
}
