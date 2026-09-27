import Foundation

public extension WCS {
    /// Crop origin is a 0-based pixel location in the source image.
    func cropped(originX: Int, originY: Int) -> WCS {
        WCS(copying: self,
            crpix: (crpix.x - Double(originX), crpix.y - Double(originY)),
            cd: (cd11, cd12, cd21, cd22),
            sipForward: sipForward, sipInverse: sipInverse)
    }

    /// Each output pixel represents the centre of a factor-by-factor source block.
    func binned(by factor: Int) -> WCS? {
        guard factor > 0 else { return nil }
        let scale = Double(factor)
        let reference = ((crpix.x - 0.5) / scale + 0.5,
                         (crpix.y - 0.5) / scale + 0.5)
        let matrix = (cd11 * scale, cd12 * scale, cd21 * scale, cd22 * scale)
        guard [reference.0, reference.1, matrix.0, matrix.1, matrix.2, matrix.3]
            .allSatisfy(\.isFinite) else { return nil }
        let forward = sipForward?.binned(by: scale)
        let inverse = sipInverse?.binned(by: scale)
        if sipForward != nil && forward == nil { return nil }
        if sipInverse != nil && inverse == nil { return nil }
        return WCS(copying: self, crpix: reference, cd: matrix,
                   sipForward: forward, sipInverse: inverse)
    }
}

private extension WCS {
    init(copying source: WCS, crpix: (Double, Double), cd: (Double, Double, Double, Double),
         sipForward: SIPPolynomial?, sipInverse: SIPPolynomial?) {
        self.crpix = (crpix.0, crpix.1)
        self.crval = source.crval
        self.cd11 = cd.0
        self.cd12 = cd.1
        self.cd21 = cd.2
        self.cd22 = cd.3
        self.projectionType = source.projectionType
        self.sipForward = sipForward
        self.sipInverse = sipInverse
        self.name = source.name
        self.nativeFrame = source.nativeFrame
        self.variant = source.variant
    }
}

private extension WCS.SIPPolynomial {
    func binned(by scale: Double) -> Self? {
        var a = self.a
        var b = self.b
        for i in 0...order {
            for j in 0...(order - i) {
                let multiplier = pow(scale, Double(i + j - 1))
                a[i][j] *= multiplier
                b[i][j] *= multiplier
                guard a[i][j].isFinite, b[i][j].isFinite else { return nil }
            }
        }
        return Self(order: order, a: a, b: b)
    }
}
