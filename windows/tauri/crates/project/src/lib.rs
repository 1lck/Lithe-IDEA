pub mod document_file;
pub mod document_watcher;
use anyhow::{Context, Result, bail};
pub mod git_watcher;
use notify::{
   Event, EventKind, RecommendedWatcher, RecursiveMode,
   event::{ModifyKind, RenameMode},
};
use notify_debouncer_full::{
   DebounceEventResult, DebouncedEvent, Debouncer, RecommendedCache, new_debouncer,
};
use std::{
   collections::HashSet,
   path::PathBuf,
   sync::{Arc, Mutex},
   time::Duration,
};

const MAX_DEBOUNCED_EVENTS_PER_BATCH: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct FileChangeEvent {
   pub path: String,
   pub event_type: FileChangeType,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FileChangeType {
   Opened,
   Reloaded,
   Deleted,
   Rescan,
}

pub trait FileChangeEmitter: Send + Sync {
   fn emit_file_change(&self, event: &FileChangeEvent);
}

pub struct FileWatcher {
   emitter: Arc<dyn FileChangeEmitter>,
   debouncer: Arc<Mutex<Option<Debouncer<RecommendedWatcher, RecommendedCache>>>>,
   watched_paths: Arc<Mutex<HashSet<PathBuf>>>,
   watched_directories: Arc<Mutex<HashSet<PathBuf>>>,
}

impl FileWatcher {
   pub fn new(emitter: Arc<dyn FileChangeEmitter>) -> Self {
      Self {
         emitter,
         debouncer: Arc::new(Mutex::new(None)),
         watched_paths: Arc::new(Mutex::new(HashSet::new())),
         watched_directories: Arc::new(Mutex::new(HashSet::new())),
      }
   }

   pub async fn watch_path(&self, path: String) -> Result<()> {
      self.watch_path_with_mode(path, true, false)
   }

   pub async fn watch_project_root(&self, path: String) -> Result<()> {
      self.watch_path_with_mode(path, true, true)
   }

   fn watch_path_with_mode(&self, path: String, recursive: bool, emit_opened: bool) -> Result<()> {
      let path_buf = PathBuf::from(&path);

      if !path_buf.exists() {
         bail!("Path does not exist: {}", path);
      }

      let mut watched_paths = self.watched_paths.lock().unwrap();
      if watched_paths.contains(&path_buf) {
         return Ok(());
      }

      self.ensure_debouncer_initialized()?;
      self.setup_path_watching(&path_buf, &mut watched_paths, recursive)?;

      if emit_opened {
         let change_event = FileChangeEvent {
            path: path_buf.to_string_lossy().to_string(),
            event_type: FileChangeType::Opened,
         };
         log::debug!(
            "[FileWatcher] Emitting opened event for: {}",
            change_event.path
         );
         self.emitter.emit_file_change(&change_event);
      }

      Ok(())
   }

   fn ensure_debouncer_initialized(&self) -> Result<()> {
      let mut debouncer_guard = self.debouncer.lock().unwrap();
      if debouncer_guard.is_some() {
         return Ok(());
      }

      let debouncer = self.create_debouncer()?;
      *debouncer_guard = Some(debouncer);
      Ok(())
   }

   fn create_debouncer(&self) -> Result<Debouncer<RecommendedWatcher, RecommendedCache>> {
      let emitter = Arc::clone(&self.emitter);
      let watched_paths = self.watched_paths.clone();
      let watched_directories = self.watched_directories.clone();

      Ok(new_debouncer(
         Duration::from_millis(300),
         None,
         move |result: DebounceEventResult| {
            match result {
               Ok(events) => Self::handle_events(
                  events,
                  emitter.as_ref(),
                  &watched_paths,
                  &watched_directories,
               ),
               Err(errors) => {
                  for error in &errors {
                     log::warn!("[FileWatcher] Native watcher error: {error}");
                  }
                  Self::emit_rescans(emitter.as_ref(), &watched_directories);
               }
            }
         },
      )?)
   }

   fn handle_events(
      events: Vec<DebouncedEvent>,
      emitter: &dyn FileChangeEmitter,
      watched_paths: &Arc<Mutex<HashSet<PathBuf>>>,
      watched_directories: &Arc<Mutex<HashSet<PathBuf>>>,
   ) {
      if events.iter().any(|event| event.need_rescan()) {
         Self::emit_rescans(emitter, watched_directories);
         return;
      }

      if events.len() > MAX_DEBOUNCED_EVENTS_PER_BATCH {
         log::warn!(
            "[FileWatcher] Collapsing {} debounced events into a bounded rescan",
            events.len()
         );
         Self::emit_rescans(emitter, watched_directories);
         return;
      }

      let watched_paths = watched_paths.lock().unwrap();
      let watched_dirs = watched_directories.lock().unwrap();

      for event in events {
         let changes = Self::classify_event(&event.event);
         for (path, event_type) in changes {
            if !Self::is_path_watched(&path, &watched_paths, &watched_dirs) {
               continue;
            }

            let change_event = FileChangeEvent {
               path: path.to_string_lossy().to_string(),
               event_type,
            };

            log::debug!(
               "[FileWatcher] Emitting file-changed event for: {} ({:?})",
               change_event.path,
               change_event.event_type
            );
            emitter.emit_file_change(&change_event);
         }
      }
   }

   fn classify_event(event: &Event) -> Vec<(PathBuf, FileChangeType)> {
      if event.need_rescan() {
         return Vec::new();
      }

      match event.kind {
         EventKind::Create(_) => event
            .paths
            .iter()
            .cloned()
            .map(|path| (path, FileChangeType::Opened))
            .collect(),
         EventKind::Remove(_) => event
            .paths
            .iter()
            .cloned()
            .map(|path| (path, FileChangeType::Deleted))
            .collect(),
         EventKind::Modify(ModifyKind::Name(RenameMode::Both)) => event
            .paths
            .iter()
            .enumerate()
            .map(|(index, path)| {
               let event_type = if index == 0 {
                  FileChangeType::Deleted
               } else {
                  FileChangeType::Opened
               };
               (path.clone(), event_type)
            })
            .collect(),
         EventKind::Modify(ModifyKind::Name(RenameMode::From)) => event
            .paths
            .iter()
            .cloned()
            .map(|path| (path, FileChangeType::Deleted))
            .collect(),
         EventKind::Modify(ModifyKind::Name(RenameMode::To)) => event
            .paths
            .iter()
            .cloned()
            .map(|path| (path, FileChangeType::Opened))
            .collect(),
         EventKind::Modify(ModifyKind::Name(_)) | EventKind::Any | EventKind::Other => event
            .paths
            .iter()
            .cloned()
            .map(|path| {
               let event_type = if path.exists() {
                  FileChangeType::Opened
               } else {
                  FileChangeType::Deleted
               };
               (path, event_type)
            })
            .collect(),
         EventKind::Modify(_) => event
            .paths
            .iter()
            .cloned()
            .map(|path| (path, FileChangeType::Reloaded))
            .collect(),
         EventKind::Access(_) => Vec::new(),
      }
   }

   fn emit_rescans(
      emitter: &dyn FileChangeEmitter,
      watched_directories: &Arc<Mutex<HashSet<PathBuf>>>,
   ) {
      let mut roots = watched_directories
         .lock()
         .unwrap()
         .iter()
         .cloned()
         .collect::<Vec<_>>();
      roots.sort();
      for path in roots {
         emitter.emit_file_change(&FileChangeEvent {
            path: path.to_string_lossy().to_string(),
            event_type: FileChangeType::Rescan,
         });
      }
   }

   fn is_path_watched(
      path: &PathBuf,
      watched_paths: &HashSet<PathBuf>,
      watched_dirs: &HashSet<PathBuf>,
   ) -> bool {
      watched_paths.contains(path) || watched_dirs.iter().any(|dir| path.starts_with(dir))
   }

   fn setup_path_watching(
      &self,
      path_buf: &PathBuf,
      watched_paths: &mut HashSet<PathBuf>,
      recursive: bool,
   ) -> Result<()> {
      let mut debouncer_guard = self.debouncer.lock().unwrap();
      let debouncer = debouncer_guard
         .as_mut()
         .context("Debouncer should be initialized")?;

      let recursive_mode = if path_buf.is_dir() && recursive {
         RecursiveMode::Recursive
      } else {
         RecursiveMode::NonRecursive
      };

      debouncer.watch(path_buf, recursive_mode)?;

      if path_buf.is_dir() {
         self.setup_directory_watching(path_buf)?;
      }

      watched_paths.insert(path_buf.clone());
      Ok(())
   }

   fn setup_directory_watching(&self, path_buf: &PathBuf) -> Result<()> {
      self
         .watched_directories
         .lock()
         .unwrap()
         .insert(path_buf.clone());

      Ok(())
   }

   pub fn stop_watching(&self, path: String) -> Result<()> {
      let path_buf = PathBuf::from(path);
      let mut watched_paths = self.watched_paths.lock().unwrap();

      if !watched_paths.contains(&path_buf) {
         bail!("Path was not being watched");
      }

      let mut debouncer_guard = self.debouncer.lock().unwrap();
      if let Some(ref mut debouncer) = *debouncer_guard {
         debouncer.unwatch(&path_buf)?;
      }

      // Commit the in-memory cleanup only after native unwatch succeeds so a
      // transient adapter failure remains retryable.
      watched_paths.remove(&path_buf);
      self.watched_directories.lock().unwrap().remove(&path_buf);

      Ok(())
   }
}

#[cfg(test)]
mod tests {
   use super::*;
   use std::{
      fs,
      sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, TryRecvError},
      time::{Instant, SystemTime},
   };

   struct ChannelEmitter(Sender<FileChangeEvent>);

   impl FileChangeEmitter for ChannelEmitter {
      fn emit_file_change(&self, event: &FileChangeEvent) {
         let _ = self.0.send(event.clone());
      }
   }

   struct TestDirectory(PathBuf);

   impl TestDirectory {
      fn new() -> Self {
         let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("system clock should follow the Unix epoch")
            .as_nanos();
         let path = std::env::temp_dir().join(format!(
            "lithe-project-watcher-{}-{unique}",
            std::process::id()
         ));
         fs::create_dir_all(&path).expect("test directory should be created");
         Self(path)
      }
   }

   impl Drop for TestDirectory {
      fn drop(&mut self) {
         let _ = fs::remove_dir_all(&self.0);
      }
   }

   fn receive_reload(receiver: &Receiver<FileChangeEvent>, path: &PathBuf) -> FileChangeEvent {
      let deadline = Instant::now() + Duration::from_secs(5);
      loop {
         let remaining = deadline.saturating_duration_since(Instant::now());
         assert!(
            !remaining.is_zero(),
            "timed out waiting for a POM reload event"
         );
         match receiver.recv_timeout(remaining) {
            Ok(event)
               if event.path == path.to_string_lossy()
                  && matches!(event.event_type, FileChangeType::Reloaded) =>
            {
               return event;
            }
            Ok(_) => continue,
            Err(RecvTimeoutError::Timeout) => {
               panic!("timed out waiting for a POM reload event")
            }
            Err(RecvTimeoutError::Disconnected) => {
               panic!("file watcher event channel disconnected")
            }
         }
      }
   }

   fn receive_change(
      receiver: &Receiver<FileChangeEvent>,
      path: &PathBuf,
      event_type: FileChangeType,
   ) -> FileChangeEvent {
      let deadline = Instant::now() + Duration::from_secs(5);
      loop {
         let remaining = deadline.saturating_duration_since(Instant::now());
         assert!(
            !remaining.is_zero(),
            "timed out waiting for {event_type:?} at {}",
            path.display()
         );
         match receiver.recv_timeout(remaining) {
            Ok(event)
               if event.path == path.to_string_lossy() && event.event_type == event_type =>
            {
               return event;
            }
            Ok(_) => continue,
            Err(RecvTimeoutError::Timeout) => {
               panic!(
                  "timed out waiting for {event_type:?} at {}",
                  path.display()
               )
            }
            Err(RecvTimeoutError::Disconnected) => {
               panic!("file watcher event channel disconnected")
            }
         }
      }
   }

   #[test]
   fn exact_nested_pom_watch_emits_reload_without_registration_event() {
      let directory = TestDirectory::new();
      let module_directory = directory.0.join("module");
      fs::create_dir_all(&module_directory).expect("module directory should be created");
      let pom_path = module_directory.join("pom.xml");
      fs::write(&pom_path, "<project/>").expect("initial POM should be written");
      let (sender, receiver) = mpsc::channel();
      let watcher = FileWatcher::new(Arc::new(ChannelEmitter(sender)));

      watcher
         .watch_path_with_mode(pom_path.to_string_lossy().to_string(), true, false)
         .expect("nested POM should be watched");
      assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));

      fs::write(&pom_path, "<project><version>2</version></project>")
         .expect("updated POM should be written");
      let event = receive_reload(&receiver, &pom_path);
      assert!(matches!(event.event_type, FileChangeType::Reloaded));
   }

   #[test]
   fn project_root_watch_observes_files_created_in_nested_directories() {
      let directory = TestDirectory::new();
      let nested_directory = directory.0.join("src").join("feature");
      fs::create_dir_all(&nested_directory).expect("nested directory should be created");
      let (sender, receiver) = mpsc::channel();
      let watcher = FileWatcher::new(Arc::new(ChannelEmitter(sender)));

      watcher
         .watch_path_with_mode(directory.0.to_string_lossy().to_string(), true, true)
         .expect("project root should be watched recursively");
      let _registration = receive_change(&receiver, &directory.0, FileChangeType::Opened);

      let nested_file = nested_directory.join("created-outside-lithe.txt");
      fs::write(&nested_file, "created").expect("nested file should be written");

      let event = receive_change(&receiver, &nested_file, FileChangeType::Opened);
      assert_eq!(event.event_type, FileChangeType::Opened);
   }

   #[test]
   fn paired_rename_preserves_old_and_new_paths() {
      let old_path = PathBuf::from("C:/workspace/src/old.rs");
      let new_path = PathBuf::from("C:/workspace/src/new.rs");
      let event = Event::new(EventKind::Modify(ModifyKind::Name(RenameMode::Both)))
         .add_path(old_path.clone())
         .add_path(new_path.clone());

      assert_eq!(
         FileWatcher::classify_event(&event),
         vec![
            (old_path, FileChangeType::Deleted),
            (new_path, FileChangeType::Opened),
         ]
      );
   }

   #[test]
   fn oversized_event_batch_collapses_to_a_rescan() {
      let root = PathBuf::from("C:/workspace");
      let events = (0..=MAX_DEBOUNCED_EVENTS_PER_BATCH)
         .map(|index| {
            DebouncedEvent::new(
               Event::new(EventKind::Create(notify::event::CreateKind::File))
                  .add_path(root.join(format!("generated-{index}.txt"))),
               Instant::now(),
            )
         })
         .collect();
      let (sender, receiver) = mpsc::channel();
      let emitter = ChannelEmitter(sender);
      let watched_paths = Arc::new(Mutex::new(HashSet::from([root.clone()])));
      let watched_directories = Arc::new(Mutex::new(HashSet::from([root.clone()])));

      FileWatcher::handle_events(
         events,
         &emitter,
         &watched_paths,
         &watched_directories,
      );

      assert_eq!(
         receiver.try_recv().expect("rescan event should be emitted"),
         FileChangeEvent {
            path: root.to_string_lossy().to_string(),
            event_type: FileChangeType::Rescan,
         }
      );
      assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));
   }
}
