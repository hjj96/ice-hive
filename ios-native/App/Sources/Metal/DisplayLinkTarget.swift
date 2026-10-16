import QuartzCore

/// CADisplayLink keeps a strong reference to its target: this small proxy holds the frame loop weakly instead.
final class DisplayLinkTarget: NSObject {
    weak var loop: FrameLoop?

    init(_ loop: FrameLoop) { self.loop = loop }

    @objc func step(_ link: CADisplayLink) { loop?.tick(link) }

    func makeLink() -> CADisplayLink { CADisplayLink(target: self, selector: #selector(step(_:))) }
}
