import AppKit

/// Los cuatro sonidos de Zas. Son sobrios, cortos y bajos de volumen: acompañan, no llaman la atención.
enum SoundEffect: CaseIterable {
    case shutter, copy, recordStart, recordStop

    /// Lo más que puede durar, en segundos. Solo el obturador pasa de 180 ms.
    var maximumDuration: Double {
        self == .shutter ? 0.26 : 0.18
    }
}

/// Sintetiza los sonidos en memoria. No hay archivos de terceros: cada muestra sale de estas cuentas.
/// El ruido del obturador usa una semilla fija, así que siempre suena igual.
enum SoundSynth {
    static let sampleRate = 44_100.0
    /// Ningún sonido pasa de este pico. La escala completa es 1.
    static let peakLimit: Float = 0.36

    private static let fadeIn = 0.003
    private static let fadeOut = 0.014

    static func samples(for effect: SoundEffect) -> [Float] {
        switch effect {
        case .shutter:
            // Dos golpes secos, como un espejo que sube y baja.
            var out = silence(0.225)
            mix(click(seconds: 0.075, tone: 1_450, seed: 11), into: &out, at: 0, gain: 0.85)
            mix(click(seconds: 0.11, tone: 960, seed: 29), into: &out, at: 0.1, gain: 1)
            return finished(out, peak: peakLimit)
        case .copy:
            // Un toque de campana muy corto.
            return finished(bell(1_568, seconds: 0.085, decay: 38), peak: 0.22)
        case .recordStart:
            // Dos notas que suben.
            var out = silence(0.17)
            mix(bell(659.25, seconds: 0.1, decay: 24), into: &out, at: 0, gain: 0.8)
            mix(bell(987.77, seconds: 0.11, decay: 22), into: &out, at: 0.058, gain: 1)
            return finished(out, peak: 0.28)
        case .recordStop:
            // Las mismas notas, de bajada.
            var out = silence(0.17)
            mix(bell(987.77, seconds: 0.1, decay: 24), into: &out, at: 0, gain: 0.8)
            mix(bell(659.25, seconds: 0.11, decay: 22), into: &out, at: 0.058, gain: 1)
            return finished(out, peak: 0.28)
        }
    }

    private static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    private static func mix(_ source: [Float], into target: inout [Float], at seconds: Double, gain: Float) {
        let start = Int(seconds * sampleRate)
        for index in source.indices where start + index < target.count {
            target[start + index] += source[index] * gain
        }
    }

    /// Una nota con su octava y su quinta apagándose antes, como un objeto pequeño de metal.
    private static func bell(_ frequency: Double, seconds: Double, decay: Double) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let phase = 2 * Double.pi * frequency * time
            let body = sin(phase) * exp(-time * decay)
            let shine = 0.28 * sin(phase * 2) * exp(-time * decay * 1.8)
            let air = 0.12 * sin(phase * 3) * exp(-time * decay * 2.6)
            return Float(body + shine + air)
        }
    }

    /// Un soplo de ruido suavizado sobre un tono que cae rápido.
    private static func click(seconds: Double, tone: Double, seed: UInt64) -> [Float] {
        let count = Int(seconds * sampleRate)
        var state = seed
        var smooth = 0.0
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(state >> 40) / Double(1 << 23) - 1
            smooth += 0.32 * (noise - smooth)
            let body = sin(2 * Double.pi * tone * time) * exp(-time * 95)
            return Float(0.62 * smooth * exp(-time * 72) + 0.38 * body)
        }
    }

    /// Lleva el sonido a su pico y le pone los fundidos: empieza y acaba en cero, sin clic.
    private static func finished(_ samples: [Float], peak: Float) -> [Float] {
        let highest = samples.map { abs($0) }.max() ?? 0
        guard highest > 0, let last = samples.indices.last, last > 0 else { return samples }
        let gain = peak / highest
        let rise = max(Int(fadeIn * sampleRate), 1)
        let fall = max(Int(fadeOut * sampleRate), 1)
        return samples.indices.map { index in
            var envelope = 1.0
            if index < rise {
                envelope *= 0.5 - 0.5 * cos(Double.pi * Double(index) / Double(rise))
            }
            if last - index < fall {
                envelope *= 0.5 - 0.5 * cos(Double.pi * Double(last - index) / Double(fall))
            }
            return samples[index] * gain * Float(envelope)
        }
    }

    /// WAV mono de 16 bits, lo más simple que `NSSound` sabe abrir desde la memoria.
    static func wav(_ samples: [Float]) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func ascii(_ text: String) {
            data.append(contentsOf: Array(text.utf8))
        }
        func littleEndian32(_ value: UInt32) {
            data.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) })
        }
        func littleEndian16(_ value: UInt16) {
            data.append(contentsOf: (0..<2).map { UInt8((value >> ($0 * 8)) & 0xFF) })
        }
        let rate = UInt32(sampleRate)
        let bytes = UInt32(samples.count * 2)
        ascii("RIFF")
        littleEndian32(36 + bytes)
        ascii("WAVE")
        ascii("fmt ")
        littleEndian32(16)
        littleEndian16(1)
        littleEndian16(1)
        littleEndian32(rate)
        littleEndian32(rate * 2)
        littleEndian16(2)
        littleEndian16(16)
        ascii("data")
        littleEndian32(bytes)
        for sample in samples {
            let value = Int16(max(min(sample, 1), -1) * Float(Int16.max))
            littleEndian16(UInt16(bitPattern: value))
        }
        return data
    }
}

/// Reproduce los sonidos respetando el ajuste "Efectos de sonido".
@MainActor
enum Sounds {
    /// Mientras se graba no suena nada: el micrófono lo recogería y se metería en el video.
    /// Inicio y fin suenan fuera de la grabación, antes de arrancar y después de parar.
    static var isMuted = false

    private static var players: [SoundEffect: NSSound] = [:]

    static var canPlay: Bool {
        Settings.shared.soundEffects && !isMuted
    }

    /// Deja los sonidos en memoria para que el primero no llegue tarde.
    static func prepare() {
        for effect in SoundEffect.allCases {
            _ = player(for: effect)
        }
    }

    private static func player(for effect: SoundEffect) -> NSSound? {
        if let player = players[effect] {
            return player
        }
        let sound = NSSound(data: SoundSynth.wav(SoundSynth.samples(for: effect)))
        players[effect] = sound
        return sound
    }

    /// Devuelve `true` si sonó.
    @discardableResult
    static func play(_ effect: SoundEffect) -> Bool {
        guard canPlay, let sound = player(for: effect) else { return false }
        // Dos capturas seguidas: la segunda vuelve a empezar en vez de perderse.
        _ = sound.stop()
        return sound.play()
    }
}
