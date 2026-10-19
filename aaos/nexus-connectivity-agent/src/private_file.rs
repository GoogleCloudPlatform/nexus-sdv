//! Write a file that only its owner can read.
//!
//! The vehicle's keys and tokens were once found world-readable on a guest where
//! SELinux runs permissive and the file mode is the only protection left. The staging
//! scripts were fixed; this closes the other half, in the code, so the result
//! does not depend on the umask of whoever started the process.

use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

pub fn write(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    // Removed first, and then created exclusively: the mode is applied when a
    // file is created, not when an existing one is truncated, so overwriting a
    // file that is already world-readable would keep it world-readable. Creating
    // exclusively also means we never write a key into a file somebody else put
    // there and still owns.
    let _ = fs::remove_file(path);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(contents)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn creates_a_file_only_its_owner_can_read() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("secret");
        write(&path, b"token").unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "mode was {mode:o}");
        assert_eq!(std::fs::read(&path).unwrap(), b"token");
    }

    /// A rerun must not inherit the permissions of whatever was there before:
    /// the mode applies to a file being created, not to one being truncated.
    #[test]
    fn replaces_a_world_readable_file_with_a_private_one() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("secret");
        std::fs::write(&path, b"old").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();

        write(&path, b"new").unwrap();

        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "mode was {mode:o}");
        assert_eq!(std::fs::read(&path).unwrap(), b"new");
    }
}
