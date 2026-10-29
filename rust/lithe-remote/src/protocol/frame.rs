//! Length-prefixed framing and the stream preamble.
//!
//! A remote command's standard output is not guaranteed to be clean: shell
//! startup files on the remote host may print banners before the server runs.
//! The server therefore writes [`PREAMBLE`] once, and the client discards any
//! bytes before it. After the preamble, every frame is a 4-byte big-endian
//! payload length followed by that many bytes of UTF-8 JSON.

use std::fmt;
use std::io::{self, Read, Write};

/// Marker written by the server before its first frame.
///
/// It starts with a newline so that it is recognized even when a startup
/// banner did not end its last line.
pub const PREAMBLE: &[u8] = b"\nLITHE-REMOTE-PROTOCOL/1\n";

/// Largest accepted frame payload in bytes.
///
/// Bulk transfers are chunked below this size, so a larger length prefix
/// means the stream is corrupt or not a Lithe server at all.
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

/// Framing failure on a protocol stream.
#[derive(Debug)]
pub enum FrameError {
    /// The underlying stream failed.
    Io(io::Error),
    /// The stream ended inside a frame or before the preamble.
    UnexpectedEof,
    /// A length prefix exceeded [`MAX_FRAME_BYTES`].
    TooLarge(usize),
    /// More than the allowed number of bytes arrived before the preamble.
    /// The captured bytes usually explain the failure, for example
    /// `lithe-remote-server: not found`.
    PreambleNotFound { noise: Vec<u8> },
}

impl fmt::Display for FrameError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "protocol stream failed: {error}"),
            Self::UnexpectedEof => formatter.write_str("protocol stream ended unexpectedly"),
            Self::TooLarge(length) => write!(
                formatter,
                "protocol frame of {length} bytes exceeds the {MAX_FRAME_BYTES}-byte limit"
            ),
            Self::PreambleNotFound { .. } => {
                formatter.write_str("the remote command did not start a Lithe server")
            }
        }
    }
}

impl std::error::Error for FrameError {}

impl From<io::Error> for FrameError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Writes one frame and flushes it.
pub fn write_frame(writer: &mut impl Write, payload: &[u8]) -> Result<(), FrameError> {
    if payload.len() > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(payload.len()));
    }
    let length = u32::try_from(payload.len()).map_err(|_| FrameError::TooLarge(payload.len()))?;
    writer.write_all(&length.to_be_bytes())?;
    writer.write_all(payload)?;
    writer.flush()?;
    Ok(())
}

/// Reads one frame. Returns `Ok(None)` when the stream ends cleanly between
/// frames, which is how a peer signals disconnection.
pub fn read_frame(reader: &mut impl Read) -> Result<Option<Vec<u8>>, FrameError> {
    let mut prefix = [0_u8; 4];
    let mut filled = 0;
    while filled < prefix.len() {
        match reader.read(&mut prefix[filled..]) {
            Ok(0) if filled == 0 => return Ok(None),
            Ok(0) => return Err(FrameError::UnexpectedEof),
            Ok(read) => filled += read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.into()),
        }
    }
    let length = u32::from_be_bytes(prefix) as usize;
    if length > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(length));
    }
    let mut payload = vec![0_u8; length];
    reader.read_exact(&mut payload).map_err(|error| {
        if error.kind() == io::ErrorKind::UnexpectedEof {
            FrameError::UnexpectedEof
        } else {
            FrameError::Io(error)
        }
    })?;
    Ok(Some(payload))
}

/// Discards bytes until [`PREAMBLE`] has been read.
///
/// At most `noise_limit` bytes may precede the preamble. The caller bounds
/// the wall-clock wait separately, because a silent stream never fails here.
pub fn skip_preamble(reader: &mut impl Read, noise_limit: usize) -> Result<(), FrameError> {
    let mut window: Vec<u8> = Vec::with_capacity(PREAMBLE.len());
    let mut noise: Vec<u8> = Vec::new();
    let mut byte = [0_u8; 1];
    loop {
        match reader.read(&mut byte) {
            Ok(0) => {
                noise.extend_from_slice(&window);
                return Err(if noise.is_empty() {
                    FrameError::UnexpectedEof
                } else {
                    FrameError::PreambleNotFound { noise }
                });
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        }
        window.push(byte[0]);
        if window.len() > PREAMBLE.len() {
            noise.push(window.remove(0));
        }
        if window == PREAMBLE {
            return Ok(());
        }
        if noise.len() > noise_limit {
            return Err(FrameError::PreambleNotFound { noise });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_round_trip_and_clean_eof_is_not_an_error() {
        let mut stream = Vec::new();
        write_frame(&mut stream, b"{\"a\":1}").unwrap();
        write_frame(&mut stream, b"").unwrap();
        let mut reader = stream.as_slice();
        assert_eq!(read_frame(&mut reader).unwrap().unwrap(), b"{\"a\":1}");
        assert_eq!(read_frame(&mut reader).unwrap().unwrap(), b"");
        assert!(read_frame(&mut reader).unwrap().is_none());
    }

    #[test]
    fn truncated_frame_is_reported() {
        let mut stream = Vec::new();
        write_frame(&mut stream, b"abcdef").unwrap();
        stream.truncate(stream.len() - 2);
        assert!(matches!(
            read_frame(&mut stream.as_slice()),
            Err(FrameError::UnexpectedEof)
        ));
        assert!(matches!(
            read_frame(&mut [0_u8, 0].as_slice()),
            Err(FrameError::UnexpectedEof)
        ));
    }

    #[test]
    fn oversized_length_prefix_is_rejected_before_allocation() {
        let prefix = ((MAX_FRAME_BYTES + 1) as u32).to_be_bytes();
        assert!(matches!(
            read_frame(&mut prefix.as_slice()),
            Err(FrameError::TooLarge(_))
        ));
    }

    // Shell startup files often print banners without a trailing newline;
    // the preamble must still be found and the frame after it intact.
    #[test]
    fn preamble_is_found_after_shell_noise() {
        let mut stream = b"Welcome to devbox\nlast login: today".to_vec();
        stream.extend_from_slice(PREAMBLE);
        write_frame(&mut stream, b"{}").unwrap();
        let mut reader = stream.as_slice();
        skip_preamble(&mut reader, 1024).unwrap();
        assert_eq!(read_frame(&mut reader).unwrap().unwrap(), b"{}");
    }

    #[test]
    fn missing_server_reports_the_captured_output() {
        let output = b"sh: 1: lithe-remote-server: not found\n";
        match skip_preamble(&mut output.as_slice(), 1024) {
            Err(FrameError::PreambleNotFound { noise }) => assert_eq!(noise, output),
            other => panic!("unexpected result: {other:?}"),
        }
    }

    #[test]
    fn unbounded_noise_stops_at_the_limit() {
        let output = vec![b'x'; 4096];
        match skip_preamble(&mut output.as_slice(), 100) {
            Err(FrameError::PreambleNotFound { noise }) => assert_eq!(noise.len(), 101),
            other => panic!("unexpected result: {other:?}"),
        }
    }
}
