#[no_mangle]
pub unsafe extern "C" fn am_wav_write_header(
    sample_rate: u32,
    channels: u16,
    data_byte_size: u32,
    out_44_bytes: *mut u8,
) {
    if out_44_bytes.is_null() {
        return;
    }

    let block_align = channels.saturating_mul(4);
    let byte_rate = sample_rate.saturating_mul(block_align as u32);
    let riff_size = 36u32.wrapping_add(data_byte_size);

    let mut hdr = [0u8; 44];
    hdr[0..4].copy_from_slice(b"RIFF");
    hdr[4..8].copy_from_slice(&riff_size.to_le_bytes());
    hdr[8..12].copy_from_slice(b"WAVE");
    hdr[12..16].copy_from_slice(b"fmt ");
    hdr[16..20].copy_from_slice(&16u32.to_le_bytes());
    hdr[20..22].copy_from_slice(&3u16.to_le_bytes()); // IEEE Float32
    hdr[22..24].copy_from_slice(&channels.to_le_bytes());
    hdr[24..28].copy_from_slice(&sample_rate.to_le_bytes());
    hdr[28..32].copy_from_slice(&byte_rate.to_le_bytes());
    hdr[32..34].copy_from_slice(&block_align.to_le_bytes());
    hdr[34..36].copy_from_slice(&32u16.to_le_bytes());
    hdr[36..40].copy_from_slice(b"data");
    hdr[40..44].copy_from_slice(&data_byte_size.to_le_bytes());

    std::ptr::copy_nonoverlapping(hdr.as_ptr(), out_44_bytes, 44);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wav_header_float32_48k_stereo() {
        let mut hdr = [0u8; 44];
        unsafe {
            am_wav_write_header(48_000, 2, 384_000, hdr.as_mut_ptr());
        }
        assert_eq!(&hdr[0..4], b"RIFF");
        assert_eq!(&hdr[8..12], b"WAVE");
        assert_eq!(&hdr[12..16], b"fmt ");
        assert_eq!(u16::from_le_bytes([hdr[20], hdr[21]]), 3);
        assert_eq!(u16::from_le_bytes([hdr[22], hdr[23]]), 2);
        assert_eq!(
            u32::from_le_bytes([hdr[24], hdr[25], hdr[26], hdr[27]]),
            48_000
        );
        assert_eq!(&hdr[36..40], b"data");
        assert_eq!(
            u32::from_le_bytes([hdr[40], hdr[41], hdr[42], hdr[43]]),
            384_000
        );
    }
}
