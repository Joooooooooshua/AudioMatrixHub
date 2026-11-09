import Foundation
import os.lock
import CAudioMatrixRust

/// Swift wrapper around the zero-allocation cross-platform Rust DSP engine (`libaudiomatrix_rust_core.a`).
/// Provides ITD/ILD speaker simulation, 4-tap early studio room reflections, click-free ramped
/// 3-band biquad Tone EQ, and soft-knee headroom limiting via C-ABI FFI.
public final class BuiltInDSPEngine {
    public static var rustCoreVersion: String {
        String(cString: am_core_version())
    }

    public static var platformBackendName: String {
        String(cString: am_platform_backend_name())
    }

    private var paramLock = os_unfair_lock_s()
    private var targetSettings: BuiltInDSPSettings
    private var pendingReset: Bool = false

    public private(set) var sampleRate: Double
    private let rustEngine: OpaquePointer

    public init(sampleRate: Double = 48000.0, settings: BuiltInDSPSettings = BuiltInDSPSettings()) {
        let clamped = max(8000.0, sampleRate)
        self.sampleRate = clamped
        self.targetSettings = settings
        guard let ptr = am_dsp_create(clamped) else {
            fatalError("Failed to allocate Rust AmDspEngine")
        }
        self.rustEngine = ptr
        am_dsp_configure(
            ptr,
            clamped,
            settings.isEnabled,
            settings.crossfeedAmount,
            settings.roomAmbience,
            settings.bassTiltDB,
            settings.midTiltDB,
            settings.trebleTiltDB,
            settings.safeHeadroomLimiter
        )
    }

    deinit {
        am_dsp_destroy(rustEngine)
    }

    public func updateSettings(_ newSettings: BuiltInDSPSettings) {
        os_unfair_lock_lock(&paramLock)
        targetSettings = newSettings
        os_unfair_lock_unlock(&paramLock)
    }

    public func currentSettings() -> BuiltInDSPSettings {
        os_unfair_lock_lock(&paramLock)
        let copy = targetSettings
        os_unfair_lock_unlock(&paramLock)
        return copy
    }

    public func setSampleRate(_ newRate: Double) {
        let clamped = max(8000.0, newRate)
        os_unfair_lock_lock(&paramLock)
        sampleRate = clamped
        os_unfair_lock_unlock(&paramLock)
    }

    public func resetState() {
        os_unfair_lock_lock(&paramLock)
        pendingReset = true
        os_unfair_lock_unlock(&paramLock)
    }

    public func processStereoInterleaved(_ buffer: UnsafeMutableBufferPointer<Float>, frameCount: Int) {
        guard frameCount > 0, let base = buffer.baseAddress, buffer.count >= frameCount * 2 else { return }

        os_unfair_lock_lock(&paramLock)
        let target = targetSettings
        let sr = sampleRate
        let shouldReset = pendingReset
        pendingReset = false
        os_unfair_lock_unlock(&paramLock)

        if shouldReset {
            am_dsp_reset(rustEngine)
        }
        am_dsp_configure(
            rustEngine,
            sr,
            target.isEnabled,
            target.crossfeedAmount,
            target.roomAmbience,
            target.bassTiltDB,
            target.midTiltDB,
            target.trebleTiltDB,
            target.safeHeadroomLimiter
        )
        am_dsp_process_stereo_interleaved(rustEngine, base, frameCount)
    }
}
