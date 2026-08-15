import AVFoundation
import Foundation

/// A steady sine used to prove the routing path deterministically.
///
/// Verifying the virtual-device leg with a live microphone requires someone to make noise at
/// the right moment, and still leaves "was that really our signal?" open. A known tone at a
/// known frequency makes the listener process's answer unambiguous.
final class ToneGenerator {
    let format: AVAudioFormat
    let node: AVAudioSourceNode

    /// Phase lives in a heap cell rather than a captured `var` because the render block runs
    /// on the realtime audio thread and must not touch actor-isolated or refcounted state.
    private let phase: UnsafeMutablePointer<Double>

    init(sampleRate: Double, frequency: Double = 440, amplitude: Float = 0.2) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            preconditionFailure("could not build a mono format at \(sampleRate)Hz")
        }
        self.format = format

        let phase = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        phase.initialize(to: 0)
        self.phase = phase

        let increment = 2 * Double.pi * frequency / sampleRate

        node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let value = Float(sin(phase.pointee)) * amplitude
                phase.pointee += increment
                if phase.pointee > 2 * .pi { phase.pointee -= 2 * .pi }

                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    data[frame] = value
                }
            }
            return noErr
        }
    }

    deinit {
        phase.deinitialize(count: 1)
        phase.deallocate()
    }
}
