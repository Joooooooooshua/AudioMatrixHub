use std::ffi::CStr;
use std::os::raw::c_char;

/// Matches Kushview Element's `detail::oscSlugify` normalization rule.
pub fn slugify_str(input: &str) -> String {
    let lower = input.to_lowercase();
    let mut result = String::with_capacity(lower.len());
    let mut last_was_dash = false;

    for ch in lower.chars() {
        let is_alnum = ch.is_ascii_lowercase() || ch.is_ascii_digit();
        if is_alnum {
            result.push(ch);
            last_was_dash = false;
        } else if !last_was_dash && !result.is_empty() {
            result.push('-');
            last_was_dash = true;
        }
    }

    if result.ends_with('-') {
        result.pop();
    }
    if result.is_empty() {
        "node".to_string()
    } else {
        result
    }
}

pub fn encode_osc_string(s: &str) -> Vec<u8> {
    let mut bytes = s.as_bytes().to_vec();
    bytes.push(0);
    let pad = (4 - (bytes.len() % 4)) % 4;
    bytes.resize(bytes.len() + pad, 0);
    bytes
}

pub fn encode_float_message(address: &str, value: f32) -> Vec<u8> {
    let mut packet = encode_osc_string(address);
    packet.extend_from_slice(&encode_osc_string(",f"));
    packet.extend_from_slice(&value.to_bits().to_be_bytes());
    packet
}

pub fn encode_int_message(address: &str, value: i32) -> Vec<u8> {
    let mut packet = encode_osc_string(address);
    packet.extend_from_slice(&encode_osc_string(",i"));
    packet.extend_from_slice(&value.to_be_bytes());
    packet
}

pub fn decode_float_message(packet: &[u8]) -> Option<(String, f32)> {
    let nul_pos = packet.iter().position(|&b| b == 0)?;
    let address = std::str::from_utf8(&packet[..nul_pos]).ok()?.to_string();
    let addr_padded = (nul_pos + 1 + 3) & !3;
    if packet.len() < addr_padded + 8 {
        return None;
    }

    let type_tag_slice = &packet[addr_padded..];
    let tag_nul = type_tag_slice.iter().position(|&b| b == 0)?;
    let type_tag = std::str::from_utf8(&type_tag_slice[..tag_nul]).ok()?;
    let tag_padded = (tag_nul + 1 + 3) & !3;
    let payload_offset = addr_padded + tag_padded;
    if type_tag != ",f" || packet.len() < payload_offset + 4 {
        return None;
    }

    let bits = u32::from_be_bytes([
        packet[payload_offset],
        packet[payload_offset + 1],
        packet[payload_offset + 2],
        packet[payload_offset + 3],
    ]);
    Some((address, f32::from_bits(bits)))
}

#[no_mangle]
pub unsafe extern "C" fn am_osc_slugify(
    input: *const c_char,
    out_buf: *mut c_char,
    out_cap: usize,
) -> usize {
    if input.is_null() || out_buf.is_null() || out_cap == 0 {
        return 0;
    }
    let raw = match CStr::from_ptr(input).to_str() {
        Ok(s) => s,
        Err(_) => return 0,
    };
    let slug = slugify_str(raw);
    let bytes = slug.as_bytes();
    let copy_len = bytes.len().min(out_cap - 1);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_buf as *mut u8, copy_len);
    *(out_buf as *mut u8).add(copy_len) = 0;
    copy_len
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_slugify_and_osc_roundtrip() {
        assert_eq!(slugify_str("Waves NX"), "waves-nx");
        assert_eq!(slugify_str("SoundID Reference"), "soundid-reference");
        assert_eq!(slugify_str("FabFilter Pro-Q 3"), "fabfilter-pro-q-3");

        let msg = encode_float_message("/element/node/waves-nx/bypass", 1.0);
        assert_eq!(msg.len() % 4, 0);
        assert_eq!(&msg[msg.len() - 4..], &[0x3F, 0x80, 0x00, 0x00]);
        let decoded = decode_float_message(&msg).unwrap();
        assert_eq!(decoded.0, "/element/node/waves-nx/bypass");
        assert_eq!(decoded.1, 1.0);

        let mut buf = [0i8; 64];
        let input = b"Waves NX\0";
        let len = unsafe {
            am_osc_slugify(
                input.as_ptr() as *const c_char,
                buf.as_mut_ptr() as *mut c_char,
                buf.len(),
            )
        };
        assert_eq!(len, 8);
        let cstr = unsafe { CStr::from_ptr(buf.as_ptr() as *const c_char) };
        assert_eq!(cstr.to_str().unwrap(), "waves-nx");
    }
}
