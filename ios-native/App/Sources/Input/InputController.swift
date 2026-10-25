import UIKit
import IceHiveCore

// ================================================================
//  INPUT — multi-touch twin sticks like 10-input.js: a finger on the
//  left half is a floating move stick, on the right half a floating
//  aim stick that fires while held; the ability / dash buttons are
//  hit-tested first. Keyboard (simulator / hardware keyboard):
//  WASD / arrows move, IJKL aim + fire, Space / Shift dash, Q / E ability.
//  All points are in view coordinates (top-left origin, y down).
// ================================================================
final class InputController {
    struct Stick {
        let touch: ObjectIdentifier
        var origin: CGPoint
        var current: CGPoint
    }
    static let stickRadius: CGFloat = 56

    private(set) var left: Stick?
    private(set) var right: Stick?
    private var abilityTouch: ObjectIdentifier?
    private var dashTouch: ObjectIdentifier?
    /// One-shot presses, consumed by `consumePresses()`.
    private(set) var abilityPressed = false
    private(set) var dashPressed = false
    private var keys = Set<Int>()
    var viewSize = CGSize(width: 874, height: 402)
    /// True after the first real touch or key: the demo autopilot hands over.
    private(set) var humanActive = false
    /// The last input came from a hardware keyboard (the coach card then names keys: «WASD — бег» …); a touch
    /// switches back to the touch texts and the ghost thumb.
    private(set) var keyboardMode = false

    /// Hit tests supplied by the HUD (view coordinates).
    var hitAbility: ((CGPoint) -> Bool)?
    var hitDash: ((CGPoint) -> Bool)?

    func reset() {
        left = nil; right = nil; abilityTouch = nil; dashTouch = nil
        abilityPressed = false; dashPressed = false
        keys.removeAll()
    }

    // ---------------------------------------------------------------- touches
    func began(_ touch: UITouch, at p: CGPoint) {
        humanActive = true
        keyboardMode = false
        let id = ObjectIdentifier(touch)
        if let h = hitAbility, h(p) { abilityPressed = true; abilityTouch = id; return }
        if let h = hitDash, h(p) { dashPressed = true; dashTouch = id; return }
        if p.x < viewSize.width * 0.5 {
            if left == nil { left = Stick(touch: id, origin: p, current: p) }
        } else {
            if right == nil { right = Stick(touch: id, origin: p, current: p) }
        }
    }

    func moved(_ touch: UITouch, at p: CGPoint) {
        let id = ObjectIdentifier(touch)
        if var s = left, s.touch == id { follow(&s, p); left = s }
        if var s = right, s.touch == id { follow(&s, p); right = s }
    }

    func ended(_ touch: UITouch) {
        let id = ObjectIdentifier(touch)
        if let s = left, s.touch == id { left = nil }
        if let s = right, s.touch == id { right = nil }
        if abilityTouch == id { abilityTouch = nil }
        if dashTouch == id { dashTouch = nil }
    }

    /// The base follows the thumb so the stick never "runs out".
    private func follow(_ s: inout Stick, _ p: CGPoint) {
        s.current = p
        let dx = p.x - s.origin.x, dy = p.y - s.origin.y
        let l = (dx * dx + dy * dy).squareRoot()
        let lim = InputController.stickRadius * 1.25
        if l > lim {
            s.origin = CGPoint(x: p.x - dx / l * lim, y: p.y - dy / l * lim)
        }
    }

    /// Stick vector: unit direction (screen, y down) and length 0…1.
    func vector(_ s: Stick) -> (x: CGFloat, y: CGFloat, len: CGFloat) {
        let dx = s.current.x - s.origin.x, dy = s.current.y - s.origin.y
        let l = (dx * dx + dy * dy).squareRoot()
        let k = l > InputController.stickRadius ? 1 / l : 1 / InputController.stickRadius
        return (dx * k, dy * k, min(1, l / InputController.stickRadius))
    }

    /// Knob offset for drawing (HUD orientation, y up).
    func knobOffset(_ s: Stick) -> CGPoint {
        let v = vector(s)
        return CGPoint(x: v.x * v.len * InputController.stickRadius, y: -v.y * v.len * InputController.stickRadius)
    }

    // ---------------------------------------------------------------- keyboard
    func keyDown(_ code: Int) {
        humanActive = true
        keyboardMode = true
        keys.insert(code)
        if code == UIKeyboardHIDUsage.keyboardSpacebar.rawValue || code == UIKeyboardHIDUsage.keyboardLeftShift.rawValue { dashPressed = true }
        if code == UIKeyboardHIDUsage.keyboardQ.rawValue || code == UIKeyboardHIDUsage.keyboardE.rawValue { abilityPressed = true }
    }

    func keyUp(_ code: Int) { keys.remove(code) }

    private func key(_ k: UIKeyboardHIDUsage) -> Bool { keys.contains(k.rawValue) }

    // ---------------------------------------------------------------- per tick
    struct Command {
        var move = Vec2(0, 0)
        var aim: Float? = nil
        var fire = false
        var ability = false
        var dash = false
        var assist: Float = 0
    }

    /// World-space command for the core (Game.setPlayerInput).
    func command() -> Command {
        var c = Command()
        var sx: Float = 0, sy: Float = 0
        if key(.keyboardD) || key(.keyboardRightArrow) { sx += 1 }
        if key(.keyboardA) || key(.keyboardLeftArrow) { sx -= 1 }
        if key(.keyboardS) || key(.keyboardDownArrow) { sy += 1 }
        if key(.keyboardW) || key(.keyboardUpArrow) { sy -= 1 }
        if let l = left {
            let v = vector(l)
            if v.len > 0.12 { sx += Float(v.x * v.len); sy += Float(v.y * v.len) }
        }
        let ml = (sx * sx + sy * sy).squareRoot()
        if ml > 1 { sx /= ml; sy /= ml }
        c.move = Game.worldFromScreen(sx, sy)
        if let r = right {
            let v = vector(r)
            if v.len > 0.2 {
                c.aim = Game.angle(of: Game.worldFromScreen(Float(v.x), Float(v.y)))
                c.assist = 0.75
            }
            c.fire = true
        } else {
            var ax: Float = 0, ay: Float = 0
            if key(.keyboardL) { ax += 1 }
            if key(.keyboardJ) { ax -= 1 }
            if key(.keyboardK) { ay += 1 }
            if key(.keyboardI) { ay -= 1 }
            if ax != 0 || ay != 0 {
                c.aim = Game.angle(of: Game.worldFromScreen(ax, ay))
                c.assist = 0.6
                c.fire = true
            }
        }
        c.ability = abilityPressed
        c.dash = dashPressed
        return c
    }

    func consumePresses() { abilityPressed = false; dashPressed = false }
}
