import Foundation
import LitheModuleAPI

extension AppModel {
    func showContributionEntry(_ contribution: ModuleContribution) {
        guard workbenchContributions.contains(contribution) else { return }
        if contribution.kind == .toolWindow {
            let state = workbenchUIRegistry.state(for: contribution, model: self)
            guard state.isVisible && state.isEnabled && !state.isPending else { return }
            workbenchFeature.customizeContribution(contribution.id, isHidden: false)
            restoreRegisteredToolWindows([contribution.id])
        } else {
            // Restoring a button or menu entry must never execute its command.
            workbenchFeature.customizeContribution(contribution.id, isHidden: false)
        }
    }

    func performToolWindowContribution(_ contribution: ModuleContribution, owner: ModuleID, openOnly: Bool = false) {
        let target = contribution.kind == .toolWindow ? contribution.id : contribution.visibility["toolWindowID"]
        guard let target, workspaceURL != nil,
              services.moduleRuntime.availableContributions()[owner]?.contains(contribution) == true else { return }
        let window = WorkbenchFeatureModel.ToolWindow(rawValue: target)
        if !openOnly && contribution.kind == .toolWindow && workbenchFeature.isVisible(window) {
            workbenchFeature.setVisibility(window, isVisible: false)
            contributionActivationTasks.removeValue(forKey: target)?.cancel()
            contributionActivationTokens.removeValue(forKey: target)
            scheduleObjectWillChangeRelay()
            return
        }
        if let pending = contributionActivationTasks[target] {
            if !openOnly && contribution.kind == .toolWindow {
                pending.cancel()
                contributionActivationTasks.removeValue(forKey: target)
                contributionActivationTokens.removeValue(forKey: target)
                scheduleObjectWillChangeRelay()
            }
            return
        }
        workbenchFeature.customizeContribution(target, isHidden: false)
        let displayRequest = workbenchFeature.beginDisplayRequest(for: window)
        let workspace = workspaceURL
        let token = UUID()
        contributionActivationTokens[target] = token
        contributionActivationTasks[target] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.contributionActivationTokens[target] == token {
                    self.contributionActivationTasks.removeValue(forKey: target)
                    self.contributionActivationTokens.removeValue(forKey: target)
                    self.scheduleObjectWillChangeRelay()
                }
            }
            do {
                await self.awaitModuleRuntimeShutdown()
                guard !Task.isCancelled, self.contributionActivationTokens[target] == token,
                      self.workspaceURL == workspace else { return }
                if let activate = self.workbenchUIRegistry.ownerActivation(for: contribution) {
                    guard await activate(self) else { return }
                } else {
                    _ = try await self.services.moduleRuntime.activate(owner)
                }
                guard !Task.isCancelled, self.contributionActivationTokens[target] == token, self.workspaceURL == workspace,
                      self.workbenchFeature.contributionPreferences[target]?.isHidden != true,
                      self.workbenchFeature.isCurrentDisplayRequest(displayRequest, for: window),
                      self.services.moduleRuntime.availableContributions()[owner]?.contains(contribution) == true else { return }
                self.workbenchFeature.setVisibility(window, isVisible: true)
            } catch {
                if !Task.isCancelled && !(error is CancellationError) { self.showNotification(error.localizedDescription) }
            }
        }
        scheduleObjectWillChangeRelay()
    }

    func cancelContributionActivations() {
        for task in contributionActivationTasks.values { task.cancel() }
        contributionActivationTasks.removeAll()
        contributionActivationTokens.removeAll()
        scheduleObjectWillChangeRelay()
    }

    func restoreRegisteredToolWindows(_ ids: [String]) {
        let owners = services.moduleRuntime.availableContributions()
        for id in ids {
            guard let contribution = workbenchContributions.first(where: { $0.id == id && $0.kind == .toolWindow }),
                  workbenchFeature.contributionPreferences[id]?.isHidden != true else { continue }
            // Saved visibility is a display intent, not proof that its owner is active.
            // Native and declarative windows share cancellation and open-only restoration.
            if let owner = owners.first(where: { $0.value.contains(contribution) })?.key {
                let state = workbenchUIRegistry.state(for: contribution, model: self)
                guard state.isVisible && state.isEnabled else { continue }
                performToolWindowContribution(contribution, owner: owner, openOnly: true)
            } else if !workbenchFeature.isVisible(.init(rawValue: id)) {
                // Host-owned setup entries can exist before an optional module is enabled.
                workbenchUIRegistry.perform(contribution, model: self)
            }
        }
    }

    func registeredContributions(at placement: ModuleContributionPlacement) -> [ModuleContribution] {
        let available = workbenchContributions
        return workbenchFeature.contributions(available, at: placement)
            .filter { workbenchUIRegistry.state(for: $0, model: self, available: available).isVisible }
    }
}
