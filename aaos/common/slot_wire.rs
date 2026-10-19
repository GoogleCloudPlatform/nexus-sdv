//! How a payload is laid out inside a fixed-size Data Tunnel slot — the middleware's way.
//!
//! The platform middleware writes every message as a protobuf length-delimited record and
//! pads it to the slot: `[varint length][message][zero padding]`
//! (`system/software_defined_vehicle/middleware/transport/rust/interface/src/codec.rs`,
//! `encode` and `decode`). The Bridge uses the same layout in both directions, so a
//! generated subscriber reads what the Bridge publishes, and what the Bridge forwards to
//! the cloud is the bare message.
//!
//! The Bridge does this on the vehicle, not the cloud: the slot size is registered inside
//! the vehicle's own APEX, and padding before the radio link would send kilobytes for a
//! six-byte command.
//!
//! Pure functions, no I/O, so both ends are testable without a device.

fn put_varint(mut v: u64, out: &mut Vec<u8>) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

/// `(value, bytes used)`; at most ten bytes, as protobuf allows.
fn get_varint(bytes: &[u8]) -> Result<(u64, usize), String> {
    let mut value = 0u64;
    for (i, b) in bytes.iter().take(10).enumerate() {
        value |= u64::from(b & 0x7f) << (7 * i);
        if b & 0x80 == 0 {
            return Ok((value, i + 1));
        }
    }
    Err("the length in front of the message does not end".to_string())
}

/// Lays `payload` out for a slot of `slot_size` bytes. `Err` when it does not fit — the
/// caller drops and counts it rather than truncating, because a cut-off message reaches
/// the receiving service as a decode error far from its cause.
pub fn pack(payload: &[u8], slot_size: usize) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(slot_size);
    put_varint(payload.len() as u64, &mut out);
    if out.len() + payload.len() > slot_size {
        return Err(format!(
            "payload {} bytes plus its {}-byte length exceeds the {slot_size}-byte slot",
            payload.len(),
            out.len()
        ));
    }
    out.extend_from_slice(payload);
    out.resize(slot_size, 0);
    Ok(out)
}

/// Reads the message back out of one slot.
pub fn unpack(slot: &[u8]) -> Result<&[u8], String> {
    let (len, used) = get_varint(slot)?;
    let end = usize::try_from(len)
        .ok()
        .and_then(|l| used.checked_add(l))
        .ok_or("length overflows")?;
    if end > slot.len() {
        return Err(format!("length says {len} bytes, slot holds {}", slot.len() - used));
    }
    Ok(&slot[used..end])
}

/// One Data Tunnel read can carry several slots; returns each slot's message in order.
pub fn unpack_all(bytes: &[u8], slot_size: usize) -> Result<Vec<&[u8]>, String> {
    if slot_size == 0 || !bytes.len().is_multiple_of(slot_size) {
        return Err(format!("{} bytes are not whole {slot_size}-byte slots", bytes.len()));
    }
    bytes.chunks(slot_size).map(unpack).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_short_payload_gets_a_one_byte_length() {
        assert_eq!(pack(&[0x08, 0xfa, 0x01], 8).unwrap(), vec![0x03, 0x08, 0xfa, 0x01, 0, 0, 0, 0]);
    }

    #[test]
    fn a_payload_of_300_bytes_gets_a_two_byte_length() {
        let slot = pack(&[0x55; 300], 400).unwrap();
        assert_eq!(&slot[..2], &[0xac, 0x02]);
        assert_eq!(unpack(&slot).unwrap(), &[0x55; 300][..]);
    }

    #[test]
    fn an_empty_payload_is_the_record_zero() {
        let slot = pack(b"", 4).unwrap();
        assert_eq!(slot, vec![0, 0, 0, 0]);
        assert_eq!(unpack(&slot).unwrap(), b"");
    }

    #[test]
    fn the_padding_is_zero_and_the_slot_full_width() {
        let slot = pack(b"ab", 16).unwrap();
        assert_eq!(slot.len(), 16);
        assert!(slot[3..].iter().all(|b| *b == 0));
    }

    #[test]
    fn a_payload_that_does_not_fit_is_refused_not_cut() {
        assert!(pack(&[1; 8], 8).is_err(), "8 bytes plus a 1-byte length need 9");
    }

    #[test]
    fn a_length_beyond_the_slot_is_an_error() {
        assert!(unpack(&[0x05, 0x01, 0x02]).is_err());
    }

    #[test]
    fn an_unterminated_length_is_an_error() {
        assert!(unpack(&[0x80, 0x80]).is_err());
    }

    #[test]
    fn several_slots_in_one_read_are_split() {
        let mut bytes = pack(&[0x08, 0x20], 8).unwrap();
        bytes.extend(pack(b"", 8).unwrap());
        assert_eq!(unpack_all(&bytes, 8).unwrap(), vec![&[0x08, 0x20][..], &[][..]]);
    }

    #[test]
    fn a_read_that_is_not_whole_slots_is_an_error() {
        assert!(unpack_all(&[0u8; 12], 8).is_err());
    }
}
