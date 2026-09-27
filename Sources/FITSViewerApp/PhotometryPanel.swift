import SwiftUI
import FITSCore
import TheiaKit

/// Shows aperture-photometry stats for each region in the document. Recomputes
/// whenever the selected image or region list changes.
struct PhotometryPanel: View {
    let session: DocumentSession
    private var table: PhotometryTable { session.photometry }

    var body: some View {
        Group {
            if session.regions.isEmpty {
                ContentUnavailableView(
                    "Nothing to measure yet",
                    systemImage: "circle.dashed",
                    description: Text("Mark a star or aperture on the image — photometry shows up here as you go.")
                )
            } else {
                content
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: session.regions) { _, _ in refresh() }
        .onChange(of: session.imageRevision) { _, _ in refresh() }
        .onChange(of: session.wcsVariant) { _, _ in refresh() }
    }

    @ViewBuilder
    private var content: some View {
        let groups = table.groups
        VStack(spacing: 0) {
            if table.isComputing {
                ProgressView("Computing…")
                    .padding(.top, 6)
            }
            List {
                ForEach(groups, id: \.tag) { group in
                    Section(header: tagHeader(group: group)) {
                        ForEach(group.rows) { item in
                            if let result = item.result {
                                row(idx: item.id, region: item.region, result: result)
                            } else {
                                Text("#\(item.id) — computing…").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func refresh() {
        table.refresh(regions: session.regions, image: session.displayed,
                      imageRevision: session.imageRevision, wcs: session.displayedWCS)
    }

    @ViewBuilder
    private func tagHeader(group: PhotometryGroup) -> some View {
        HStack(spacing: 8) {
            Text(group.tag.isEmpty ? "Untagged" : group.tag).font(.subheadline.weight(.semibold))
            Spacer()
            Text("n=\(group.rows.count)").foregroundStyle(.secondary)
            Text("Σ=\(fmt(group.totalSum))").foregroundStyle(.secondary)
            if let netSum = group.totalNetFlux {
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
