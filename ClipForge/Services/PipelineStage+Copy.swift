import Foundation

extension PipelineStage {
    var friendlyTitle: String {
        switch self {
        case .ingest:     return "Setting up your project"
        case .concat:     return "Combining your source videos"
        case .audio:      return "Extracting audio"
        case .transcribe: return "Transcribing speech"
        case .generate:   return "Picking the best moments"
        case .render:     return "Rendering your clips"
        }
    }

    var friendlySubtitle: String {
        switch self {
        case .ingest:     return "Creating folders and getting your files ready."
        case .concat:     return "Stitching everything into one master timeline."
        case .audio:      return "Pulling the audio track for transcription."
        case .transcribe: return "Listening to your video and writing down every word."
        case .generate:   return "An AI is reading the transcript and choosing clips that match your prompt."
        case .render:     return "Cutting and exporting the final videos."
        }
    }

    var stepIndex: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
}
