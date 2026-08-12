#pragma once

#include "MainWindow.g.h"
#include "workbench_session.h"

namespace winrt::Lithe::implementation {

struct MainWindow : MainWindowT<MainWindow> {
    MainWindow();
    ~MainWindow();

    winrt::fire_and_forget ShowWelcomeClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget OpenWorkspaceClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget CloseWorkspaceClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget CloneRepositoryClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget PreviewMarkdownClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RefreshWorkspaceClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RevealWorkspaceClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void SaveDocumentClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void MarkdownEditorModeClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget MarkdownPreviewModeClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);

    void RefreshGitClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void FetchGitClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget PushGitClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget PullGitClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget IntegrateGitClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget CherryPickSelectedCommitClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget RevertSelectedCommitClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget ResetToRevisionClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void ContinueGitOperationClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void AbortGitOperationClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void SkipGitOperationClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void StageSelectedClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void UnstageSelectedClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget DiscardSelectedClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget RollbackBlockedPathClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void BlockedChangesFilterChanged(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void StageAllClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void CommitClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void CommitAndPushClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void LoadGitHistoryClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void LoadGitStashesClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void LoadShelvesClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void ToggleBlameClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget CompareReferenceClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget SwitchReferenceClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget CreateBranchClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget RenameBranchClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget DeleteBranchClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget CreateStashClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void ApplyStashClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void PopStashClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget DropStashClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget CreateShelfClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RestoreShelfClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget DeleteShelfClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void StageHunkClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void UnstageHunkClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget DiscardHunkClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);

    void StartTerminalClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void NewTerminalClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void CloseTerminalClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void StopTerminalClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void InterruptTerminalClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RestartTerminalClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void ClearTerminalClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RunMavenCleanClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RunMavenTestClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RunMavenPackageClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RunMavenVerifyClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RunMavenInstallClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void StopProcessClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RunCurrentJavaClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RunSpringBootClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RunSelectedConfigurationClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void StopJavaClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void DebugCurrentJavaClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void DebugSpringBootClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void DebugSelectedConfigurationClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget AttachDebuggerClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void ToggleBreakpointClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void ContinueDebuggerClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void PauseDebuggerClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void StepIntoDebuggerClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void StepOverDebuggerClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void StepOutDebuggerClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void StopDebuggerClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void InspectDebuggerThreadsClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void InspectDebuggerStackClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void InspectDebuggerVariablesClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void GoToDefinitionClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void FindUsagesClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);

    void ToggleBottomPanelClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget OpenSearchEverywhereClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget OpenProjectReplaceClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void FocusFindClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void CloseFindClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void FindNextClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void FindPreviousClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void FindOptionChanged(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget ShowCommandPaletteClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget ShowSettingsClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget GenerateAICommitClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget ConfigureAICommitClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void CheckForUpdatesClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RefreshAnalysisClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void ClearProblemsClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);

    void ProjectItemInvoked(
        Microsoft::UI::Xaml::Controls::TreeView const&,
        Microsoft::UI::Xaml::Controls::TreeViewItemInvokedEventArgs const&);
    void ProjectTreeRightTapped(
        IInspectable const&, Microsoft::UI::Xaml::Input::RightTappedRoutedEventArgs const&);
    winrt::fire_and_forget NewFileClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget NewDirectoryClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget RenameWorkspaceItemClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget DuplicateWorkspaceItemClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    winrt::fire_and_forget DeleteWorkspaceItemClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void CopyRelativePathClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void CopyAbsolutePathClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void RevealSelectedItemClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);

    void ChangeItemClick(IInspectable const&, Microsoft::UI::Xaml::Controls::ItemClickEventArgs const&);
    void SearchResultClick(IInspectable const&, Microsoft::UI::Xaml::Controls::ItemClickEventArgs const&);
    void NavigationItemClick(IInspectable const&, Microsoft::UI::Xaml::Controls::ItemClickEventArgs const&);
    void GitHistoryItemClick(IInspectable const&, Microsoft::UI::Xaml::Controls::ItemClickEventArgs const&);
    void CommitFileClick(IInspectable const&, Microsoft::UI::Xaml::Controls::ItemClickEventArgs const&);
    void HistoryItemClick(IInspectable const&, Microsoft::UI::Xaml::Controls::ItemClickEventArgs const&);
    winrt::fire_and_forget RestoreHistoryClick(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void DebugVariableClick(IInspectable const&, Microsoft::UI::Xaml::Controls::ItemClickEventArgs const&);
    void GitStashSelectionChanged(
        IInspectable const&, Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
    void ShelfSelectionChanged(
        IInspectable const&, Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
    void DiffOverviewSelectionChanged(
        IInspectable const&, Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
    void SidebarTabSelectionChanged(
        IInspectable const&, Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
    void BottomToolSelectionChanged(
        IInspectable const&, Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);

    void WorkspaceSearchKeyDown(
        IInspectable const&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const&);
    void FindBoxKeyDown(
        IInspectable const&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const&);
    void TerminalInputKeyDown(
        IInspectable const&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const&);
    void TerminalSessionSelectionChanged(
        IInspectable const&, Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
    void TerminalShellSelectionChanged(
        IInspectable const&, Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
    void TerminalShellLostFocus(
        IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void DebugExpressionKeyDown(
        IInspectable const&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const&);
    void RootKeyDown(IInspectable const&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const&);
    void EditorTextChanged(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void EditorSelectionChanged(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void EditorLoaded(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void EditorGutterPointerPressed(
        IInspectable const&,
        Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const&);
    void KeepExternalEditorVersionClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void LoadExternalDiskVersionClick(IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
    void FindTextChanged(
        IInspectable const&, Microsoft::UI::Xaml::Controls::TextChangedEventArgs const&);
    void EditorTabSelectionChanged(
        IInspectable const&, Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
    void CloseActiveEditorClick(
        IInspectable const&,
        Microsoft::UI::Xaml::Input::KeyboardAcceleratorInvokedEventArgs const&);
    winrt::fire_and_forget EditorTabCloseRequested(
        Microsoft::UI::Xaml::Controls::TabView const&,
        Microsoft::UI::Xaml::Controls::TabViewTabCloseRequestedEventArgs const&);
    void SidebarSplitterDragDelta(
        IInspectable const&, Microsoft::UI::Xaml::Controls::Primitives::DragDeltaEventArgs const&);
    void BottomSplitterDragDelta(
        IInspectable const&, Microsoft::UI::Xaml::Controls::Primitives::DragDeltaEventArgs const&);
    void RootSizeChanged(IInspectable const&, Microsoft::UI::Xaml::SizeChangedEventArgs const&);

private:
    struct NavigationTarget {
        std::string relativePath;
        std::optional<std::filesystem::path> absolutePath;
        std::uint64_t line = 0;
        std::uint64_t utf16Column = 0;
    };
    struct DirtyDocumentSaveSequence {
        std::vector<std::pair<std::string, std::string>> documents;
        std::function<void()> completion;
        std::size_t index = 0;
    };
    enum class GutterActionKind {
        BlameCommit,
        Usages,
        Implementations,
        InlayPosition,
    };
    struct GutterAction {
        GutterActionKind kind = GutterActionKind::InlayPosition;
        std::uint64_t line = 0;
        std::uint64_t utf16Column = 0;
        std::size_t startColumn = 0;
        std::size_t endColumn = 0;
        std::string value;
    };

    HWND windowHandle();
    void configureWindow();
    void configureSession();
    void configureTimers();
    void configureEditorScroll();
    hstring ui(std::string_view source) const;
    void applyUiTranslations();
    void translateElement(Microsoft::UI::Xaml::DependencyObject const& element);
    Windows::Foundation::IAsyncOperation<
        Microsoft::UI::Xaml::Controls::ContentDialogResult>
        showDialog(Microsoft::UI::Xaml::Controls::ContentDialog const& dialog);
    void setStatus(std::string message);
    void showBottomTool(std::uint32_t index);
    void cacheCurrentDocument();
    winrt::fire_and_forget continueAfterDirtyDocuments(
        std::string actionTitle, std::function<void()> completion);
    void saveNextDirtyDocument(std::shared_ptr<DirtyDocumentSaveSequence> state);
    void resetWorkspaceUI();
    void openDocument(std::string path,
                      std::optional<std::uint64_t> line = std::nullopt,
                      std::optional<std::uint64_t> utf16Column = std::nullopt);
    void openExternalDocument(const std::filesystem::path& path,
                              std::optional<std::uint64_t> line = std::nullopt,
                              std::optional<std::uint64_t> utf16Column = std::nullopt);
    Microsoft::UI::Xaml::Controls::TabViewItem ensureEditorTab(const std::string& path);
    void updateTabHeader(const std::string& path);
    void remapEditorPaths(std::string_view oldPath, std::string_view newPath);
    std::vector<std::string> selectedChangePaths();
    std::string selectedTreePath();
    std::string selectedTreeParentPath();
    void removeEditorTab(Microsoft::UI::Xaml::Controls::TabViewItem const& tab);
    winrt::fire_and_forget closeEditorTab(
        Microsoft::UI::Xaml::Controls::TabViewItem const& tab);
    void configureEditorTabContextMenu(
        Microsoft::UI::Xaml::Controls::TabViewItem const& tab,
        std::string path);
    void saveWorkbenchState();
    void scheduleWorkbenchStateSave();
    void restoreWorkbenchState();
    void applyLayout(const lithe::windows::WorkbenchLayoutState& state);
    lithe::windows::WorkbenchLayoutState currentLayout();

    std::string editorText();
    void setEditorText(std::string_view value);
    void updateEditorPresentation();
    void renderMarkdownPreview(std::string_view source);
    void renderMarkdownHTML(lithe::windows::winui::MarkdownRenderResult result);
    void updateLineNumbers();
    void invokeGutterAnnotation(std::uint64_t line, double x);
    void applySyntaxHighlighting();
    void updateCursorPosition();
    void navigateEditor(std::uint64_t line, std::uint64_t utf16Column);
    std::pair<std::uint64_t, std::uint64_t> editorPosition();
    void rebuildFindMatches();
    void selectFindMatch(bool forward);
    void copyText(std::string_view value);
    void revealPath(const std::filesystem::path& path, bool selectFile);
    void clearNavigationList(Microsoft::UI::Xaml::Controls::ListView const& list);
    static bool isExternalDocument(std::string_view key);
    static std::string externalDocumentKey(const std::filesystem::path& path);
    static std::filesystem::path externalDocumentPath(std::string_view key);

    void renderWorkspace(lithe::windows::app::WorkspaceFeatureState state);
    void handleDirectoryChanges(std::vector<lithe::windows::DirectoryChangeSource::Change> changes);
    void appendWorkspaceNode(
        Microsoft::UI::Xaml::Controls::TreeViewNode const& parent,
        const lithe::windows::WorkspaceNodeDto& node,
        bool isRoot = false);
    void renderDocument(lithe::windows::app::DocumentFeatureState state);
    void renderSearch(lithe::windows::app::SearchFeatureState state);
    void renderSearchEverywhere(lithe::windows::app::SearchEverywhereFeatureState state);
    winrt::fire_and_forget showProjectReplacementPreview(
        lithe::windows::app::ReplacementFeatureState state);
    winrt::fire_and_forget renderProjectReplacementApplied(
        lithe::windows::winui::ProjectReplacementApplyResult result);
    void renderGit(lithe::windows::app::GitFeatureState state);
    void renderGitChanges();
    winrt::fire_and_forget showCheckoutConflict(
        lithe::windows::app::GitPendingCheckout pending,
        std::vector<std::string> blockingPaths);
    winrt::fire_and_forget showIntegrationConflict(
        lithe::windows::app::GitPendingIntegration pending,
        std::vector<std::string> blockingPaths,
        bool blocksEntirely);
    void renderDiff(const lithe::windows::GitDiffDto& diff);
    void renderHistory(lithe::windows::app::HistoryFeatureState state);
    void renderShelves(lithe::windows::app::ShelfFeatureState state);
    void renderAnalysis(lithe::windows::app::MavenJavaFeatureState state);
    void renderJavaDebug(lithe::windows::app::JavaDebugSnapshot snapshot);
    void renderLanguageServerState(bool ready, std::string message);
    void renderJavaDiagnostics(lithe::windows::winui::JavaDiagnosticsResult result);
    void renderJavaNavigation(lithe::windows::winui::JavaNavigationResult result);
    void renderAICommitResult(lithe::windows::winui::AICommitGenerationResult result);
    winrt::fire_and_forget renderUpdateCheck(
        lithe::windows::winui::WindowsUpdateCheckResult result);
    winrt::fire_and_forget renderUpdateDownload(
        lithe::windows::winui::WindowsUpdateDownloadResult result);
    Windows::Foundation::IAsyncOperation<bool> configureAICommitSettings();
    void appendDebugVariable(const lithe::windows::app::JavaDebugVariable& variable,
                             int depth);
    void renderTerminals(lithe::windows::app::TerminalFeatureState state);
    void renderTerminalOutput(std::string id);
    void appendBuildOutput(std::string output);

    HWND hwnd_{nullptr};
    Microsoft::UI::Dispatching::DispatcherQueue dispatcher_{nullptr};
    std::unique_ptr<lithe::windows::winui::WorkbenchSession> session_;
    std::unordered_map<std::uintptr_t, std::string> treePaths_;
    std::unordered_set<std::string> directoryPaths_;
    std::unordered_map<std::uintptr_t, NavigationTarget> navigationTargets_;
    std::unordered_map<std::uintptr_t, std::string> debugVariableIDs_;
    std::unordered_map<std::uintptr_t, std::string> historyPaths_;
    std::unordered_map<std::string, std::string> openDocuments_;
    std::unordered_set<std::string> dirtyPaths_;
    std::string activePath_;
    std::string activeTerminalID_;
    std::string pendingMarkdownSource_;
    std::string selectedGitCommit_;
    std::string selectedGitStash_;
    std::string selectedShelf_;
    std::string selectedHunk_;
    std::string selectedHistoryContentPath_;
    std::string selectedHistoryPath_;
    std::string pendingHistoryContentPath_;
    std::optional<std::string> loadedHistoryContent_;
    std::optional<std::uint64_t> pendingNavigationLine_;
    std::optional<std::uint64_t> pendingNavigationColumn_;
    std::vector<std::pair<int32_t, int32_t>> findMatches_;
    lithe::windows::app::JavaDebugSnapshot debugSnapshot_;
    std::optional<lithe::windows::GitBlameResponseDto> blame_;
    std::optional<lithe::windows::JavaCodeVisionDto> codeVision_;
    std::optional<lithe::windows::JavaStructureDto> javaStructure_;
    std::vector<GutterAction> gutterActions_;
    std::optional<lithe::windows::app::GitPendingIntegration> pendingIntegration_;
    std::optional<lithe::windows::GitStatusDto> gitStatus_;
    std::vector<std::string> gitConflictPaths_;
    std::vector<std::string> pendingIntegrationPaths_;
    std::string blamePath_;
    bool blameVisible_ = false;
    std::size_t findMatchIndex_ = 0;
    std::chrono::steady_clock::time_point lastShiftPress_{};
    Microsoft::UI::Xaml::Controls::ScrollViewer editorScrollViewer_{nullptr};
    Microsoft::UI::Xaml::Controls::ListView searchEverywhereDialogResults_{nullptr};
    Microsoft::UI::Dispatching::DispatcherQueueTimer debugPollTimer_{nullptr};
    Microsoft::UI::Dispatching::DispatcherQueueTimer workbenchSaveTimer_{nullptr};
    Microsoft::UI::Dispatching::DispatcherQueueTimer markdownPreviewTimer_{nullptr};
    winrt::event_token editorScrollToken_{};
    winrt::event_token debugPollToken_{};
    winrt::event_token workbenchSaveToken_{};
    winrt::event_token markdownPreviewToken_{};
    bool editorUpdating_ = false;
    bool editorFormatting_ = false;
    bool simplifiedChinese_ = false;
    bool bottomPanelVisible_ = true;
    bool restoringWorkbench_ = false;
    bool externalConflictVisible_ = false;
    bool terminalUiUpdating_ = false;
    std::uint64_t terminalRevision_ = 0;
    double bottomPanelHeight_ = 290.0;
};

} // namespace winrt::Lithe::implementation

namespace winrt::Lithe::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}
