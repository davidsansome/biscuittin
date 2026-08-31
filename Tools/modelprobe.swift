import Foundation
import CoreML

// Prints a CoreML model's real input/output description. The authority on tensor shapes,
// names and preprocessing is the compiled model itself — never the docs or the export script.
//
//   swift Tools/modelprobe.swift Hatbox/Resources/Models/mobileclip_s0_image.mlpackage

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)

let compiled: URL
if url.pathExtension == "mlmodelc" {
    compiled = url
} else {
    print("compiling \(url.lastPathComponent)…")
    compiled = try MLModel.compileModel(at: url)
}

let model = try MLModel(contentsOf: compiled)
let desc = model.modelDescription

func describe(_ feature: MLFeatureDescription) -> String {
    var out = "  \(feature.name): \(feature.type.rawValue)"
    if let c = feature.multiArrayConstraint {
        out += " multiArray shape=\(c.shape) dataType=\(c.dataType.rawValue)"
    }
    if let i = feature.imageConstraint {
        out += " image \(i.pixelsWide)x\(i.pixelsHigh) pixelFormat=\(i.pixelFormatType)"
    }
    return out
}

print("--- inputs ---")
for (_, f) in desc.inputDescriptionsByName { print(describe(f)) }
print("--- outputs ---")
for (_, f) in desc.outputDescriptionsByName { print(describe(f)) }

if !desc.metadata.isEmpty {
    print("--- metadata ---")
    for (k, v) in desc.metadata {
        let text = "\(v)".prefix(300)
        print("  \(k.rawValue): \(text)")
    }
}
