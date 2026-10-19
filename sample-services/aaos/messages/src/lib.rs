//! The message types of the AAOS examples, for the cloud side.
//!
//! In the vehicle `vsidlc` generates the code for these messages from a VSIDL catalog. Here
//! the same `.proto` files are compiled at build time (build.rs), so a cloud service fills
//! in a struct and never writes a byte by hand:
//!
//! ```
//! use nexus_sample_messages::sample::{DoorCommand, door_command::Action};
//! use prost::Message;
//! let command = DoorCommand { action: Action::Lock as i32 };
//! assert_eq!(command.encode_to_vec(), [0x08, 0x01]);
//! ```

/// `aaos/nexus-sdv-sample/catalog/nexus_sample.proto` — what the cloud sends into the vehicle.
pub mod sample {
    include!(concat!(env!("OUT_DIR"), "/com.nexussdv.sample.rs"));
}

/// `aaos/nexus-sdk-catalog/nexus_sdk.proto` — `Uplink` and `Command`, the Bridge's generic paths.
pub mod sdk {
    include!(concat!(env!("OUT_DIR"), "/com.nexussdv.sdk.rs"));
}

/// Google's quickstart catalog — what the vehicle's `Manager` publishes.
pub mod quickstart {
    include!(concat!(env!("OUT_DIR"), "/com.android.sdv.sample.quickstart.rs"));
}

#[cfg(test)]
mod tests {
    use super::quickstart::TirePressure;
    use super::sample::{DoorCommand, PressureLimit, door_command::Action};
    use prost::Message;

    // The bytes below are the ones the two services wrote by hand until 2026-10-10 and the
    // vehicle has been decoding since 2026-10-07. Generated code must produce exactly these.
    #[test]
    fn a_door_command_is_the_bytes_the_vehicle_knows() {
        assert_eq!(DoorCommand { action: Action::Lock as i32 }.encode_to_vec(), [0x08, 0x01]);
        assert_eq!(DoorCommand { action: Action::Unlock as i32 }.encode_to_vec(), [0x08, 0x02]);
    }

    #[test]
    fn a_pressure_limit_is_the_bytes_the_vehicle_knows() {
        assert_eq!(PressureLimit { max_pressure: 250 }.encode_to_vec(), [0x08, 0xfa, 0x01]);
        // 6200, the marker of the acceptance run of 2026-10-07: 08 b8 30.
        assert_eq!(PressureLimit { max_pressure: 6200 }.encode_to_vec(), [0x08, 0xb8, 0x30]);
    }

    #[test]
    fn a_command_survives_the_wire() {
        let c = super::sdk::Command { target: "my-bundle".into(), name: "blink".into(), payload: vec![1, 2, 3] };
        assert_eq!(super::sdk::Command::decode(c.encode_to_vec().as_slice()).unwrap(), c);
        let u = super::sdk::Uplink { name: "temp".into(), payload: vec![9] };
        assert_eq!(super::sdk::Uplink::decode(u.encode_to_vec().as_slice()).unwrap(), u);
    }

    #[test]
    fn a_tire_pressure_from_the_vehicle_is_read() {
        // 240 as Google's Manager publishes it: field 1, varint 240.
        assert_eq!(TirePressure::decode(&[0x08, 0xf0, 0x01][..]).unwrap().pressure, 240);
        assert!(TirePressure::decode(&[0x08][..]).is_err(), "a cut-off message is refused");
    }
}
