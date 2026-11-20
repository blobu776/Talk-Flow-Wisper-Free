import Foundation
import Speech
import Accelerate
import AVFoundation

enum SpokenEdits {
    // Match commands only inside the current recording. Earlier dictations are never input.
    private static let command = try! NSRegularExpression(pattern:
        #"(?i)\b(?:(?:actually|no|wait)[\s,.:;!?–—-]+)*(?:(?:scratch|delete|remove|clear|erase|discard)\s+(?:(all\s+(?:of\s+)?(?:that|this)|everything)|(?:(?:from\s+)?(?:my|the)\s+last\s+(?:thought|sentence)|that|this\s+thought))|start\s+over)\b"#)
    static func apply(_ raw:String) -> String {
        let ns = raw as NSString
        let matches = command.matches(in:raw,range:NSRange(location:0,length:ns.length))
        var result = "", position = 0
        for match in matches {
            result += ns.substring(with:NSRange(location:position,length:match.range.location-position))
            let phrase = ns.substring(with:match.range).lowercased()
            if match.range(at:1).location != NSNotFound || phrase.hasSuffix("start over") { result = "" }
            else {
                let trimmed = result.trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:".,;:!?–—-")))
                if let last = trimmed.rangeOfCharacter(from:CharacterSet(charactersIn:".!?;\n"),options:.backwards) {
                    result = String(trimmed[..<last.upperBound]).trimmingCharacters(in:.whitespacesAndNewlines) + " "
                } else { result = "" }
            }
            position = NSMaxRange(match.range)
            while position < ns.length, let scalar = UnicodeScalar(ns.character(at:position)),
                  CharacterSet(charactersIn:",.;:!?–—- \t\n").contains(scalar) { position += 1 }
        }
        result += ns.substring(from:position)
        return result.trimmingCharacters(in:.whitespacesAndNewlines)
    }
}

// The input tap stays open across recognition requests. Rotate on a quiet boundary
// so a recognizer revising partial hypotheses can only revise its current phrase.
final class SpeechInput: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var quietTime = 0.0, elapsed = 0.0
    private var heardVoice = false, queued = false
    private var gain: Float = 1
    func use(_ next:SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        request = next
        elapsed = 0; quietTime = 0; heardVoice = false; queued = false
    }
    func append(_ buffer:AVAudioPCMBuffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let request else { return false }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return false }
        let seconds = Double(n) / buffer.format.sampleRate
        if let channels = buffer.floatChannelData, !buffer.format.isInterleaved {
            var rms:Float = 0, peak:Float = 0
            for i in 0..<Int(buffer.format.channelCount) {
                var r:Float = 0, p:Float = 0
                vDSP_rmsqv(channels[i],1,&r,vDSP_Length(n))
                vDSP_maxmgv(channels[i],1,&p,vDSP_Length(n))
                rms = max(rms,r); peak = max(peak,p)
            }
            if rms > 0.001 { heardVoice = true; quietTime = 0 } else { quietTime += seconds }
            // Bounded gain for soft speech, with peak protection and no noise gate.
            let wanted:Float = min(8,max(1,0.06 / max(rms,0.0001)))
            gain += (wanted - gain) * 0.12
            var applied = min(gain,0.97 / max(peak,0.0001))
            for i in 0..<Int(buffer.format.channelCount) { vDSP_vsmul(channels[i],1,&applied,channels[i],1,vDSP_Length(n)) }
        }
        request.append(buffer)
        elapsed += seconds
        guard !queued, (heardVoice && quietTime >= 1.8) || elapsed >= 48 else { return false }
        queued = true
        return true
    }
}
