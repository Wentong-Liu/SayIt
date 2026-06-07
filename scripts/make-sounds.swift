#!/usr/bin/env swift
//
// make-sounds.swift — Synthesize SayIt's dictation start/stop chime cues with AVFoundation.
//
// Design (the approved "chime" audition — lower & softer revision):
//   Two short, warm bell-like chimes. A two-note ASCENDING phrase (G4 -> D5)
//   signals that dictation has BEGUN (start.caf); a two-note DESCENDING phrase
//   (D5 -> G4) signals that it has ENDED (stop.caf). Each chime is a fundamental
//   sine plus softened octave (0.3) and fifth (0.22) partials, shaped by a fast
//   attack, an exponential decay, and a per-note release taper to 0 so it reads
//   as a soft pluck rather than a beep and leaves no click at the note's end.
//   Mono, 44100 Hz, written verbatim as CAF.
//
// This generator is FULLY DETERMINISTIC (no randomness): running it twice
// produces byte-stable audio, so the committed start.caf / stop.caf are
// reproducible from source. The script is committed alongside the generated
// assets purely for provenance.
//
// Usage:
//   swift scripts/make-sounds.swift <outputDir>
//     Writes start.caf and stop.caf into <outputDir>
//     (normally SayItCore/Sources/SayItCore/Resources, bundled via Bundle.module).
//
import AVFoundation
import Foundation

// MARK: - Constants

/// Sample rate for the generated cues (mono).
let sr = 44100.0

/// Note frequencies (Hz) used by the two-note phrases.
let G4 = 392.00
let D5 = 587.33

// MARK: - Synthesis

/// Add one bell-like chime into `buf`, starting at `start` seconds and lasting `dur` seconds.
///
/// The timbre is the EXACT approved design and must not be improvised:
///   s   = sin(2πft) + 0.3·sin(2π·2f·t) + 0.22·sin(2π·1.5f·t)   (fundamental + softened octave + fifth)
///   env = t < attack ? t/attack : exp(-3.6·(t-attack))          (20 ms linear attack, exp decay)
///         · per-note release taper to 0 over the final `release` seconds (kills the end-of-note click)
///   buf[start·sr + i] += s · env · 0.6
func chime(_ f: Double, _ start: Double, _ dur: Double, into buf: inout [Float]) {
    let attack = 0.02, release = 0.06
    let startSample = Int(start * sr)
    let count = Int(dur * sr)
    for i in 0..<count {
        let t = Double(i) / sr
        let s = sin(2 * .pi * f * t)
            + 0.3 * sin(2 * .pi * 2 * f * t)
            + 0.22 * sin(2 * .pi * 1.5 * f * t)
        var env = t < attack ? t / attack : exp(-3.6 * (t - attack))
        if t > dur - release { env *= max(0, (dur - t) / release) }  // release taper to 0 at note end fixes the click
        let index = startSample + i
        guard index < buf.count else { break }
        buf[index] += Float(s * env * 0.6)
    }
}

/// Normalize the buffer's peak to `peak`, then apply a short linear fade-out at the tail.
/// Both steps run on the summed buffer (after all chimes are mixed) to avoid clipping and clicks.
func finalize(_ buf: inout [Float], peak: Float = 0.85, fadeSeconds: Double = 0.02) {
    // Normalize peak to `peak`.
    let maxAbs = buf.reduce(Float(0)) { max($0, abs($1)) }
    if maxAbs > 0 {
        let gain = peak / maxAbs
        for i in buf.indices { buf[i] *= gain }
    }
    // Linear fade-out over the last `fadeSeconds` to kill the tail click.
    let fadeSamples = Int(fadeSeconds * sr)
    if fadeSamples > 0, fadeSamples <= buf.count {
        let start = buf.count - fadeSamples
        for i in 0..<fadeSamples {
            let factor = Float(fadeSamples - 1 - i) / Float(fadeSamples - 1)
            buf[start + i] *= factor
        }
    }
}

// MARK: - CAF writing

/// Write a mono Float sample buffer to `url` as a CAF file at 44100 Hz.
func writeCAF(_ samples: [Float], to url: URL) {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else {
        FileHandle.standardError.write("Failed to create audio format\n".data(using: .utf8)!)
        exit(1)
    }
    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(samples.count)) else {
        FileHandle.standardError.write("Failed to create PCM buffer\n".data(using: .utf8)!)
        exit(1)
    }
    pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
    guard let channel = pcmBuffer.floatChannelData?[0] else {
        FileHandle.standardError.write("Failed to access PCM channel data\n".data(using: .utf8)!)
        exit(1)
    }
    samples.withUnsafeBufferPointer { src in
        channel.update(from: src.baseAddress!, count: samples.count)
    }
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: pcmBuffer)
        print("Wrote \(url.path) (\(samples.count) frames)")
    } catch {
        FileHandle.standardError.write("Write failed (\(url.path)): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Cue builders

/// Buffer length (seconds) for both cues — enough to hold the second note's decay tail.
let bufferSeconds = 0.64
let bufferLength = Int(bufferSeconds * sr)

/// Ascending two-note phrase: G4 then D5 (dictation BEGINS).
func makeStart() -> [Float] {
    var buf = [Float](repeating: 0, count: bufferLength)
    chime(G4, 0.0, 0.52, into: &buf)
    chime(D5, 0.13, 0.47, into: &buf)
    finalize(&buf)
    return buf
}

/// Descending two-note phrase: D5 then G4 (dictation ENDS).
func makeStop() -> [Float] {
    var buf = [Float](repeating: 0, count: bufferLength)
    chime(D5, 0.0, 0.52, into: &buf)
    chime(G4, 0.13, 0.49, into: &buf)
    finalize(&buf)
    return buf
}

// MARK: - Command dispatch

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("Usage: make-sounds.swift <outputDir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = args[1]

func outURL(_ name: String) -> URL {
    URL(fileURLWithPath: (outDir as NSString).appendingPathComponent(name))
}

writeCAF(makeStart(), to: outURL("start.caf"))
writeCAF(makeStop(), to: outURL("stop.caf"))
