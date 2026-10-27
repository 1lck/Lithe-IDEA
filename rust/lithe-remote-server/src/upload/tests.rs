//! Upload isolation and cancellation without relying on slow disks or sleeps.

use super::*;
use crate::session::Session;

#[test]
fn busy_file_does_not_block_other_uploads_or_connection_cleanup() {
    let session = Session::new(true).unwrap();
    let context = Context {
        session: Arc::clone(&session),
        connection: 1,
        closed: Arc::default(),
    };
    let directory = crate::fs::handle(
        methods::FS_TEMP_DIRECTORY,
        json!({"prefix": "lithe-upload-lock-test"}),
    )
    .unwrap();
    let root = PathBuf::from(directory["path"].as_str().unwrap());
    let _cleanup = Cleanup(Arc::clone(&session), root.clone());
    let start = |name: &str| {
        session.uploads.handle(&context, methods::FS_UPLOAD_START,
        json!({"path": root.join(name), "size": 1, "sha256": format!("{:x}", Sha256::digest(b"x")), "mode": 0o400})).unwrap()["uploadId"].as_u64().unwrap()
    };
    let first = start("first");
    let second = start("second");
    let slot = lock(&session.uploads.0).get(&first).cloned().unwrap();
    // The per-file critical section represents a worker stalled in file I/O.
    // Other operations must finish while it remains held, on this same thread.
    let busy = lock(&slot.upload);
    let chunk = |id| json!({"uploadId": id, "offset": 0, "data": methods::encode_bytes(b"x")});
    assert_eq!(
        session
            .uploads
            .handle(&context, methods::FS_UPLOAD_CHUNK, chunk(first))
            .unwrap_err()
            .code,
        ErrorCode::Busy
    );
    session
        .uploads
        .handle(&context, methods::FS_UPLOAD_CHUNK, chunk(second))
        .unwrap();
    session
        .uploads
        .handle(
            &context,
            methods::FS_UPLOAD_COMMIT,
            json!({"uploadId": second}),
        )
        .unwrap();
    session.uploads.release(1);
    assert!(slot.cancelled.load(Ordering::Acquire));
    assert!(lock(&session.uploads.0).is_empty());
    drop(busy);
    drop(slot);
    assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
    assert_eq!(fs::read(root.join("second")).unwrap(), b"x");
}

#[test]
fn expiry_and_abort_do_not_wait_for_an_active_upload_worker() {
    let session = Session::new(true).unwrap();
    let context = Context {
        session: Arc::clone(&session),
        connection: 1,
        closed: Arc::default(),
    };
    let expired = Arc::new(Slot {
        owner: 1,
        expires: Instant::now(),
        cancelled: AtomicBool::new(false),
        upload: Mutex::new(None),
    });
    lock(&session.uploads.0).insert(1, Arc::clone(&expired));
    let busy = lock(&expired.upload);
    session.uploads.expire();
    assert!(expired.cancelled.load(Ordering::Acquire));
    drop(busy);
    let active = Arc::new(Slot {
        owner: 1,
        expires: Instant::now() + LIFETIME,
        cancelled: AtomicBool::new(false),
        upload: Mutex::new(None),
    });
    lock(&session.uploads.0).insert(2, Arc::clone(&active));
    let busy = lock(&active.upload);
    session
        .uploads
        .handle(&context, methods::FS_UPLOAD_ABORT, json!({"uploadId": 2}))
        .unwrap();
    assert!(active.cancelled.load(Ordering::Acquire));
    drop(busy);
    session.terminate_all();
}

struct Cleanup(Arc<Session>, PathBuf);
impl Drop for Cleanup {
    fn drop(&mut self) {
        self.0.terminate_all();
        fs::remove_dir_all(&self.1).unwrap();
    }
}
