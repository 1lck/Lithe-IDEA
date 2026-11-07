//! A settings reload revokes only one plugin's models in one build window.
//! Existing operation draining and Core detection remain the owners.
use super::*;

impl BuildRegistry {
    pub(crate) fn settings_reload_pending(&self, label: &str, root: &str, plugin: &str) -> bool {
        self.windows.get(label).is_some_and(|window| {
            window.workspace_root.as_deref() == Some(root)
                && window.settings_reloads.contains(plugin)
        })
    }
    pub(crate) fn begin_settings_reload(
        &mut self,
        label: &str,
        root: &str,
        plugin: &str,
    ) -> Result<u64, String> {
        let window = self
            .windows
            .get_mut(label)
            .ok_or("plugin.settings.staleContext")?;
        if window.workspace_root.as_deref() != Some(root)
            || window.execution_suspended > 0
            || window.refresh_pending
        {
            return Err("plugin.settings.staleContext".into());
        }
        // Invalidate old publications before taking the operation drain snapshot.
        if window.settings_reloads.insert(plugin.into()) {
            let revision = window.settings_revisions.entry(plugin.into()).or_default();
            *revision = revision.saturating_add(1);
            for session in window
                .sessions
                .values_mut()
                .filter(|session| session.plugin_id == plugin)
            {
                session.revision = session.revision.saturating_add(1);
            }
        }
        Ok(window.generation)
    }

    pub(crate) fn finish_settings_reload(&mut self, label: &str, generation: u64, plugin: &str) {
        if let Some(window) = self
            .windows
            .get_mut(label)
            .filter(|window| window.generation == generation)
        {
            window.settings_reloads.remove(plugin);
        }
    }

    pub(crate) fn reload_settings(
        &mut self,
        core: &dyn BuildCoreExecutor,
        packages: &dyn BuildPackageSource,
        persistence: &dyn BuildOptionsPersistence,
        label: &str,
        root: &str,
        generation: u64,
        plugin: &str,
        checkpoint: &dyn Fn() -> Result<(), String>,
    ) -> Result<BuildView, String> {
        self.check_generation(label, generation)?;
        let previous = self
            .windows
            .get(label)
            .ok_or("plugin.settings.staleContext")?;
        if previous.workspace_root.as_deref() != Some(root)
            || !previous.settings_reloads.contains(plugin)
        {
            return Err("plugin.settings.staleContext".into());
        }
        // Reuse detection on a candidate registry. Other plugins' sessions,
        // model revisions and generation stay intact, including other windows.
        let mut candidate = BuildRegistry::new();
        candidate.windows.insert(label.into(), previous.clone());
        candidate.refresh_selected_checked(
            core,
            packages,
            persistence,
            label,
            root,
            checkpoint,
            Some(plugin),
        )?;
        checkpoint()?;
        let next = candidate
            .windows
            .remove(label)
            .ok_or("plugin.settings.staleContext")?;
        let current = self
            .windows
            .get_mut(label)
            .ok_or("plugin.settings.staleContext")?;
        let mut sessions = next.sessions;
        for (key, session) in &mut sessions {
            if let Some(previous) = current.sessions.get(key) {
                session.revision = previous.revision.saturating_add(1);
            }
        }
        current.sessions.retain(|(id, _, _), _| id != plugin);
        current.sessions.extend(sessions);
        current.issues.retain(|issue| issue["pluginID"] != plugin);
        current.issues.extend(next.issues);
        current.settings_reloads.remove(plugin);
        Ok(self.view(label))
    }
}
