use std::os::raw::c_char;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    MacOSCoreAudio,
    WindowsWasapi,
    LinuxPipeWire,
}

impl BackendKind {
    pub const fn as_c_str(self) -> &'static [u8] {
        match self {
            BackendKind::MacOSCoreAudio => b"macos-coreaudio\0",
            BackendKind::WindowsWasapi => b"windows-wasapi\0",
            BackendKind::LinuxPipeWire => b"linux-pipewire\0",
        }
    }

    pub const fn name(self) -> &'static str {
        match self {
            BackendKind::MacOSCoreAudio => "macos-coreaudio",
            BackendKind::WindowsWasapi => "windows-wasapi",
            BackendKind::LinuxPipeWire => "linux-pipewire",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PlatformAudioDevice {
    pub id: String,
    pub name: String,
    pub is_input: bool,
    pub is_output: bool,
    pub sample_rate: f64,
}

/// Cross-platform OS audio driver abstraction so Windows (WASAPI) and Linux (PipeWire)
/// shells can share the exact same Rust DSP, lock-free SPSC ring buffer, and OSC/WAV engine.
pub trait AudioPlatformBackend {
    fn backend_kind(&self) -> BackendKind;
    fn supports_process_tap(&self) -> bool;
    fn default_sample_rate(&self) -> f64 {
        48_000.0
    }
}

pub struct NativePlatformBackend;

impl AudioPlatformBackend for NativePlatformBackend {
    fn backend_kind(&self) -> BackendKind {
        #[cfg(target_os = "macos")]
        {
            BackendKind::MacOSCoreAudio
        }
        #[cfg(target_os = "windows")]
        {
            BackendKind::WindowsWasapi
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        {
            BackendKind::LinuxPipeWire
        }
    }

    fn supports_process_tap(&self) -> bool {
        #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
        {
            true
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
        {
            false
        }
    }
}

const CORE_VERSION_CSTR: &[u8] = b"2.0.0\0";

#[no_mangle]
pub extern "C" fn am_core_version() -> *const c_char {
    CORE_VERSION_CSTR.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn am_platform_backend_name() -> *const c_char {
    let backend = NativePlatformBackend;
    backend.backend_kind().as_c_str().as_ptr() as *const c_char
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn test_backend_detection_and_c_exports() {
        let backend = NativePlatformBackend;
        let kind = backend.backend_kind();
        assert!(backend.supports_process_tap());
        assert_eq!(backend.default_sample_rate(), 48_000.0);

        unsafe {
            let ver = CStr::from_ptr(am_core_version()).to_str().unwrap();
            assert_eq!(ver, "2.0.0");

            let name = CStr::from_ptr(am_platform_backend_name()).to_str().unwrap();
            assert_eq!(name, kind.name());
        }
    }
}
