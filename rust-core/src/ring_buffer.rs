use std::sync::atomic::{AtomicU64, Ordering};

/// Lock-free Single-Producer Single-Consumer (SPSC) stereo Float32 ring buffer.
/// Uses power-of-two capacity masking and `Acquire`/`Release` atomic frame cursors.
pub struct AmRingBuffer {
    pub capacity_frames: usize,
    capacity_mask: usize,
    storage_ptr: *mut f32,
    write_cursor: AtomicU64,
    read_cursor: AtomicU64,
}

unsafe impl Send for AmRingBuffer {}
unsafe impl Sync for AmRingBuffer {}

impl AmRingBuffer {
    pub fn new(capacity_frames: usize) -> Self {
        let mut pow2 = 256usize;
        while pow2 < capacity_frames {
            pow2 <<= 1;
        }
        let mut buf = vec![0.0f32; pow2 * 2].into_boxed_slice();
        let storage_ptr = buf.as_mut_ptr();
        std::mem::forget(buf);

        Self {
            capacity_frames: pow2,
            capacity_mask: pow2 - 1,
            storage_ptr,
            write_cursor: AtomicU64::new(0),
            read_cursor: AtomicU64::new(0),
        }
    }

    pub fn reset(&self) {
        self.read_cursor.store(0, Ordering::Release);
        self.write_cursor.store(0, Ordering::Release);
    }

    pub fn available_frames(&self) -> usize {
        let w = self.write_cursor.load(Ordering::Acquire);
        let r = self.read_cursor.load(Ordering::Acquire);
        w.saturating_sub(r) as usize
    }

    /// Producer-side write. Returns number of stereo frames written.
    ///
    /// # Safety
    /// Caller must ensure `src` is valid for reading `frame_count * 2` `f32` values.
    pub unsafe fn write(&self, src: *const f32, frame_count: usize) -> usize {
        if frame_count == 0 || src.is_null() {
            return 0;
        }
        let r = self.read_cursor.load(Ordering::Acquire);
        let w = self.write_cursor.load(Ordering::Relaxed);
        let used = w.saturating_sub(r) as usize;
        let free_frames = self.capacity_frames.saturating_sub(used);
        let to_write = frame_count.min(free_frames);
        if to_write == 0 {
            return 0;
        }

        let start_idx = (w as usize) & self.capacity_mask;
        let first_part = to_write.min(self.capacity_frames - start_idx);
        let second_part = to_write - first_part;

        std::ptr::copy_nonoverlapping(src, self.storage_ptr.add(start_idx * 2), first_part * 2);
        if second_part > 0 {
            std::ptr::copy_nonoverlapping(src.add(first_part * 2), self.storage_ptr, second_part * 2);
        }

        self.write_cursor
            .store(w.wrapping_add(to_write as u64), Ordering::Release);
        to_write
    }

    /// Consumer-side read. Returns exact number of stereo frames read.
    ///
    /// # Safety
    /// Caller must ensure `dst` is valid for writing `frame_count * 2` `f32` values.
    pub unsafe fn read(&self, dst: *mut f32, frame_count: usize) -> usize {
        if frame_count == 0 || dst.is_null() {
            return 0;
        }
        let w = self.write_cursor.load(Ordering::Acquire);
        let r = self.read_cursor.load(Ordering::Relaxed);
        let available = w.saturating_sub(r) as usize;
        let to_read = frame_count.min(available);
        if to_read == 0 {
            return 0;
        }

        let start_idx = (r as usize) & self.capacity_mask;
        let first_part = to_read.min(self.capacity_frames - start_idx);
        let second_part = to_read - first_part;

        std::ptr::copy_nonoverlapping(self.storage_ptr.add(start_idx * 2), dst, first_part * 2);
        if second_part > 0 {
            std::ptr::copy_nonoverlapping(self.storage_ptr, dst.add(first_part * 2), second_part * 2);
        }

        self.read_cursor
            .store(r.wrapping_add(to_read as u64), Ordering::Release);
        to_read
    }
}

impl Drop for AmRingBuffer {
    fn drop(&mut self) {
        if !self.storage_ptr.is_null() {
            unsafe {
                let len = self.capacity_frames * 2;
                let _ = Box::from_raw(std::ptr::slice_from_raw_parts_mut(self.storage_ptr, len));
            }
            self.storage_ptr = std::ptr::null_mut();
        }
    }
}

#[no_mangle]
pub extern "C" fn am_ring_create(capacity_frames: usize) -> *mut AmRingBuffer {
    Box::into_raw(Box::new(AmRingBuffer::new(capacity_frames)))
}

#[no_mangle]
pub unsafe extern "C" fn am_ring_destroy(ptr: *mut AmRingBuffer) {
    if !ptr.is_null() {
        drop(Box::from_raw(ptr));
    }
}

#[no_mangle]
pub unsafe extern "C" fn am_ring_reset(ptr: *mut AmRingBuffer) {
    if let Some(ring) = ptr.as_ref() {
        ring.reset();
    }
}

#[no_mangle]
pub unsafe extern "C" fn am_ring_available_frames(ptr: *const AmRingBuffer) -> usize {
    ptr.as_ref().map(|r| r.available_frames()).unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn am_ring_write(
    ptr: *const AmRingBuffer,
    src: *const f32,
    frame_count: usize,
) -> usize {
    match ptr.as_ref() {
        Some(ring) => ring.write(src, frame_count),
        None => 0,
    }
}

#[no_mangle]
pub unsafe extern "C" fn am_ring_read(
    ptr: *const AmRingBuffer,
    dst: *mut f32,
    frame_count: usize,
) -> usize {
    match ptr.as_ref() {
        Some(ring) => ring.read(dst, frame_count),
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_spsc_sequential_and_wrap_around() {
        unsafe {
            let ring = am_ring_create(256);
            assert_eq!((*ring).capacity_frames, 256);

            let mut write_a = vec![0.0f32; 180 * 2];
            for i in 0..180 {
                write_a[i * 2] = i as f32;
                write_a[i * 2 + 1] = -(i as f32);
            }
            assert_eq!(am_ring_write(ring, write_a.as_ptr(), 180), 180);
            assert_eq!(am_ring_available_frames(ring), 180);

            let mut read_a = vec![0.0f32; 120 * 2];
            assert_eq!(am_ring_read(ring, read_a.as_mut_ptr(), 120), 120);
            assert_eq!(read_a[0], 0.0);
            assert_eq!(read_a[119 * 2], 119.0);
            assert_eq!(read_a[119 * 2 + 1], -119.0);
            assert_eq!(am_ring_available_frames(ring), 60);

            // Wraps across 256-frame boundary
            let mut write_b = vec![0.0f32; 150 * 2];
            for i in 0..150 {
                write_b[i * 2] = (1000 + i) as f32;
                write_b[i * 2 + 1] = (2000 + i) as f32;
            }
            assert_eq!(am_ring_write(ring, write_b.as_ptr(), 150), 150);
            assert_eq!(am_ring_available_frames(ring), 210);

            let mut read_b = vec![-1.0f32; 210 * 2];
            assert_eq!(am_ring_read(ring, read_b.as_mut_ptr(), 210), 210);
            assert_eq!(read_b[0], 120.0);
            assert_eq!(read_b[59 * 2], 179.0);
            assert_eq!(read_b[60 * 2], 1000.0);
            assert_eq!(read_b[209 * 2], 1149.0);
            assert_eq!(read_b[209 * 2 + 1], 2149.0);
            assert_eq!(am_ring_available_frames(ring), 0);

            am_ring_destroy(ring);
        }
    }
}
