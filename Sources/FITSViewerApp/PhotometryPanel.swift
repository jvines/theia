import SwiftUI
import FITSCore

/// Shows aperture-photometry stats for each region in the document. Recomputes
/// whenever the selected image or region list changes.
struct PhotometryPanel: View {
    let regions: [Region]
    let imageProvider: () -> FITSImage?
    let wcsProvider: () -> WCS?

    @State private var results: [Int: PhotometryResult] = [:]
    @State private var computing = false

    var body: some View {
        if regions.isEmpty {
            ContentUnavailableView(
                "Nothing to measure yet",
                systemImage: "circle.dashed",
                description: Text("Mark a star or aperture on the image — photometry shows up here as you go.")
            )
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let pairs: [(Int, Region, PhotometryResult?)] = regions.enumerated().map { idx, r in
            (idx, r, results[idx])
        }
        let grouped = Dictionary(grouping: pairs, by: { $0.1.attributes["tag"] ?? "" })
        let tags = grouped.keys.sorted { (a, b) in
            if a.isEmpty { return false }; if b.isEmpty { return true }; return a < b
        }
        VStack(spacing: 0) {
            if computing {
                ProgressView("Computing…")
                    .padding(.top, 6)
            }
            List {
                ForEach(tags, id: \.self) { tag in
                    Section(header: tagHeader(tag: tag, items: grouped[tag] ?? [])) {
                        ForEach(grouped[tag] ?? [], id: \.0) { idx, region, result in
                            if let result {
                                row(idx: idx, region: region, result: result)
                            } else {
                                Text("#\(idx) — computing…").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { recompute() }
        .onChange(of: regions.count) { _, _ in recompute() }
        .onChange(of: regionsDigest) { _, _ in recompute() }
    }

    private var regionsDigest: Int {
        var h = Hasher()
        for r in regions {
            h.combine(r.attributes["tag"] ?? "")
            switch r.shape {
            case .circle(let c, let rad): h.combine("c"); h.combine(c.x); h.combine(c.y); h.combine(rad.value)
            case .box(let c, let w, let h2, _): h.combine("b"); h.combine(c.x); h.combine(c.y); h.combine(w.value); h.combine(h2.value)
            case .ellipse(let c, let rx, let ry, _): h.combine("e"); h.combine(c.x); h.combine(c.y); h.combine(rx.value); h.combine(ry.value)
            case .annulus(let c, let i, let o): h.combine("a"); h.combine(c.x); h.combine(c.y); h.combine(i.value); h.combine(o.value)
            case .polygon(let pts): h.combine("p"); for p in pts { h.combine(p.x); h.combine(p.y) }
            case .point(let p): h.combine("pt"); h.combine(p.x); h.combine(p.y)
            }
        }
        return h.finalize()
    }

    private func recompute() {
        guard let image = imageProvider() else { return }
        let wcs = wcsProvider()
        let snapshot = regions
        computing = true
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [Int: PhotometryResult] = [:]
            for (idx, r) in snapshot.enumerated() {
                if let res = Photometry.measure(region: r, image: image, wcs: wcs) {
                    out[idx] = res
                }
            }
            DispatchQueue.main.async {
                self.results = out
                self.computing = false
            }
        }
    }

    @ViewBuilder
    private func tagHeader(tag: String, items: [(Int, Region, PhotometryResult?)]) -> some View {
        let sums = items.compactMap { $0.2?.sum }
        let totalSum = sums.reduce(0, +)
        let netSums = items.compactMap { $0.2?.skySubtractedFlux }
        let netSum = netSums.reduce(0, +)
        HStack(spacing: 8) {
            Text(tag.isEmpty ? "Untagged" : tag).font(.subheadline.weight(.semibold))
            Spacer()
            Text("n=\(items.count)").foregroundStyle(.secondary)
            Text("Σ=\(fmt(totalSum))").foregroundStyle(.secondary)
            if !netSums.isEmpty {
                Text("Σ−sky=\(fmt(netSum))").foregroundStyle(.secondary)
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    @ViewBuilder
    private func row(idx: Int, region: Region, result: PhotometryResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("#\(idx) — \(shortLabel(region))")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    Text("n").foregroundStyle(.secondary)
                    Text("\(result.pixelCount)").font(.system(.caption, design: .monospaced))
                    Text("sum").foregroundStyle(.secondary)
                    Text(fmt(result.sum)).font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("mean").foregroundStyle(.secondary)
                    Text(fmt(result.mean)).font(.system(.caption, design: .monospaced))
                    Text("med").foregroundStyle(.secondary)
                    Text(fmt(result.median)).font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("σ").foregroundStyle(.secondary)
                    Text(fmt(result.stddev)).font(.system(.caption, design: .monospaced))
                    Text("min/max").foregroundStyle(.secondary)
                    Text("\(fmt(result.min)) / \(fmt(result.max))").font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("centroid").foregroundStyle(.secondary)
                    Text(String(format: "(%.2f, %.2f)", result.centroid.x, result.centroid.y))
                        .font(.system(.caption, design: .monospaced))
                    if let sky = result.sky {
                        Text("sky")
                            .foregroundStyle(.secondary)
                        Text(fmt(sky))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                if let net = result.skySubtractedFlux {
                    GridRow {
                        Text("flux − sky")
                            .foregroundStyle(.secondary)
                        if let err = result.skySubtractedFluxError {
                            Text("\(fmt(net)) ± \(fmt(err))")
                                .font(.system(.caption, design: .monospaced))
                        } else {
                            Text(fmt(net)).font(.system(.caption, design: .monospaced))
                        }
                    }
                } else {
                    GridRow {
                        Text("σ_Poisson")
                            .foregroundStyle(.secondary)
                        Text(fmt(result.sumError))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                if let psf = result.psfFlux, let fwhm = result.psfFWHM {
                    GridRow {
                        Text("PSF flux")
                            .foregroundStyle(.secondary)
                        Text(fmt(psf)).font(.system(.caption, design: .monospaced))
                        Text("FWHM")
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2f px", fwhm))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func shortLabel(_ r: Region) -> String {
        switch r.shape {
        case .circle(_, let r):       return "circle r=\(fmt(r.value))"
        case .box(_, let w, let h, _): return "box \(fmt(w.value))×\(fmt(h.value))"
        case .ellipse(_, let rx, let ry, _): return "ellipse rx=\(fmt(rx.value)) ry=\(fmt(ry.value))"
        case .annulus(_, let i, let o): return "annulus \(fmt(i.value))…\(fmt(o.value))"
        case .polygon(let p):         return "polygon (\(p.count))"
        case .point: return "point"
        }
    }

    private func fmt(_ v: Double) -> String {
        if abs(v) >= 1e4 || (v != 0 && abs(v) < 0.01) { return String(format: "%.3e", v) }
        return String(format: "%.4g", v)
    }
}
