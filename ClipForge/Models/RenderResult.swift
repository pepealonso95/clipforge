import Foundation

struct RenderResult {
    let scriptName: String
    let outputDir: URL
    let scriptMarkdown: URL
    let stitched: URL
    let clipFiles: [URL]
}
