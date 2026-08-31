import SwiftUI
import MapKit

/// Metadata modal shown by the viewer's info button (requirement 9, §13.3).
///
/// Sections hide themselves when they have nothing to show, so a screenshot with no camera or
/// location data does not render a wall of blanks.
struct InfoSheet: View {
    @ObservedObject var viewModel: InfoViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                fileSection
                if viewModel.metadata.hasCameraInfo { cameraSection }
                if viewModel.metadata.hasLocation { locationSection }
                availabilitySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { viewModel.load() }
    }

    // MARK: - Sections

    private var fileSection: some View {
        Section("File") {
            if let name = viewModel.metadata.fileName {
                InfoRow(label: "Name", value: name)
            }
            if let date = viewModel.metadata.captureDate {
                InfoRow(label: "Captured", value: date.formatted(date: .long, time: .shortened))
            }
            if let size = viewModel.metadata.pixelSize {
                InfoRow(label: "Dimensions",
                        value: "\(Int(size.width)) × \(Int(size.height))",
                        detail: megapixels(size))
            }
            if let bytes = viewModel.metadata.fileSizeBytes {
                InfoRow(label: "Size", value: AssetMetadata.formattedFileSize(bytes))
            }
            if let duration = viewModel.metadata.durationSeconds {
                InfoRow(label: "Duration", value: AssetMetadata.formattedDuration(duration))
            }
        }
    }

    private var cameraSection: some View {
        Section("Camera") {
            if let model = cameraName {
                InfoRow(label: "Device", value: model)
            }
            if let lens = viewModel.metadata.lensModel {
                InfoRow(label: "Lens", value: lens)
            }
            if let exposure = exposureSummary {
                InfoRow(label: "Exposure", value: exposure)
            }
            if let focal = viewModel.metadata.focalLengthMM {
                InfoRow(label: "Focal length", value: "\(Int(focal.rounded())) mm")
            }
        }
    }

    private var locationSection: some View {
        Section("Location") {
            if let coordinate = viewModel.metadata.coordinate {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))) {
                    Marker("", coordinate: coordinate)
                }
                .frame(height: 150)
                .listRowInsets(EdgeInsets())
                .allowsHitTesting(false)

                if let place = viewModel.metadata.placeName {
                    InfoRow(label: "Place", value: place)
                }
                InfoRow(label: "Coordinates",
                        value: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
            }
        }
    }

    private var availabilitySection: some View {
        Section("Availability") {
            if viewModel.metadata.sources.isEmpty {
                Text("Unknown").foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.metadata.sources, id: \.rawValue) { source in
                    Label(source.rawValue,
                          systemImage: source == .device ? "iphone" : "icloud")
                }
            }
        }
    }

    // MARK: - Derived values

    private var cameraName: String? {
        let parts = [viewModel.metadata.cameraMake, viewModel.metadata.cameraModel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var exposureSummary: String? {
        var parts: [String] = []
        if let f = viewModel.metadata.fNumber { parts.append(String(format: "ƒ/%.1f", f)) }
        if let exposure = viewModel.metadata.exposureSeconds {
            parts.append(AssetMetadata.formattedExposure(exposure))
        }
        if let iso = viewModel.metadata.iso { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func megapixels(_ size: CGSize) -> String? {
        let mp = size.width * size.height / 1_000_000
        guard mp >= 0.1 else { return nil }
        return String(format: "%.1f MP", mp)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
