#include "core_dto.h"
#include "core_requests.h"

#include <cassert>
#include <string>

using namespace lithe::windows;

int main() {
    const auto parsed = parseJson(R"({"text":"\u4f60\u597d \ud83d\ude00","u":18446744073709551615,"n":-7.5})");
    assert(parsed.succeeded());
    assert(objectValue(*parsed.value, "text")->asString() != nullptr);
    assert(*objectValue(*parsed.value, "text")->asString() == "你好 😀");
    assert(objectValue(*parsed.value, "u")->asUInt() == 18446744073709551615ULL);
    assert(objectValue(*parsed.value, "n")->asDouble() == -7.5);
    assert(!parseJson("{\"broken\":").succeeded());
    const auto malformedEnvelope = decodeCoreEnvelope("{\"broken\":");
    assert(!malformedEnvelope &&
           malformedEnvelope.error().code == CoreErrorCode::ParseFailed);

    const auto pingEnvelope = decodeCoreEnvelope(
        R"({"id":"ping","ok":true,"data":{"protocolVersion":1,"coreVersion":"0.1.0"}})");
    const auto ping = decodeCorePing(*pingEnvelope);
    assert(ping && ping->protocolVersion == 1 && ping->coreVersion == "0.1.0");

    const auto error = decodeCoreEnvelope(
        R"({"id":"req-1","ok":false,"error":{"code":"permission_denied","message":"No access","details":"Win32 detail"}})");
    assert(error && !error->ok && error->hasError);
    assert(error->error.code == CoreErrorCode::PermissionDenied);
    assert(error->error.details && *error->error.details == "Win32 detail");

    const auto snapshotEnvelope = decodeCoreEnvelope(R"({
        "id":"req-2","ok":true,"data":{
          "root":{"path":"","name":"project","isDirectory":true,
                   "children":[{"path":"README.md","name":"README.md","isDirectory":false}]},
          "files":["README.md"]
        }
    })");
    assert(snapshotEnvelope);
    const auto snapshot = decodeWorkspaceSnapshot(*snapshotEnvelope);
    assert(snapshot && snapshot->root.children.size() == 1);
    assert(snapshot->root.children.front().children.empty());

    const auto searchEnvelope = decodeCoreEnvelope(R"({
        "id":"req-3","ok":true,"data":{"matches":[
          {"kind":"content","path":"src/Main.java","line":null,"preview":"class Main"},
          {"kind":"symbol","path":"src/Main.java","line":4,"preview":"void run","symbolName":"run"}
        ]}
    })");
    assert(searchEnvelope);
    const auto search = decodeSearchResponse(*searchEnvelope);
    assert(search && search->matches.size() == 2);
    assert(!search->matches[0].line && !search->matches[0].symbolName);
    assert(search->matches[1].line && *search->matches[1].line == 4);

    const auto replacementEnvelope = decodeCoreEnvelope(R"({
        "id":"replace","ok":true,"data":{"files":[
          {"path":"a.txt","matches":[{"line":1,"before":"foo","after":"bar","occurrenceCount":2}],
           "originalText":"foo","replacementText":"bar"}
        ]}
    })");
    const auto replacement = decodeReplacementPreview(*replacementEnvelope);
    assert(replacement && replacement->files.size() == 1 &&
           replacement->files[0].matches[0].occurrenceCount == 2 &&
           replacement->files[0].originalText == "foo");

    const auto markdownEnvelope = decodeCoreEnvelope(R"({
        "id":"markdown","ok":true,"data":{"html":"<h1>Preview</h1>"}
    })");
    assert(markdownEnvelope);
    const auto markdown = decodeMarkdownRender(*markdownEnvelope);
    assert(markdown && markdown->html == "<h1>Preview</h1>");

    const auto diffEnvelope = decodeCoreEnvelope(R"({
        "id":"req-4","ok":true,"data":{"patch":"@@","rows":[
          {"oldLine":1,"newLine":1,"left":"same","kind":"context","hunkId":"hunk-0"},
          {"oldLine":2,"newLine":2,"left":"old","right":"new","kind":"changed","hunkId":"hunk-0"}
        ],"hunks":[{"id":"hunk-0","header":"@@","patch":"@@"}]}
    })");
    assert(diffEnvelope);
    const auto diff = decodeGitDiff(*diffEnvelope);
    assert(diff && diff->rows.size() == 2);
    assert(!diff->rows[0].hasRight && diff->rows[0].hunkId == "hunk-0");
    assert(diff->rows[1].hasRight && diff->rows[1].right == "new");

    const auto shelfPatchesEnvelope = decodeCoreEnvelope(R"({
        "id":"shelf-patches","ok":true,"data":{
          "stagedPatch":"staged","workingTreePatch":"working"
        }
    })");
    const auto shelfPatches = decodeGitShelfPatches(*shelfPatchesEnvelope);
    assert(shelfPatches && shelfPatches->stagedPatch == "staged" &&
           shelfPatches->workingTreePatch == "working");

    const auto gitStatusEnvelope = decodeCoreEnvelope(R"({
        "id":"req-6","ok":true,"data":{
          "repositoryRoot":null,"branch":"main","changes":[
            {"path":"src/Main.java","status":" M","staged":false,"worktree":true,"untracked":false},
            {"path":"README.md","originalPath":"README.old","status":"R ","staged":true,"worktree":false,"untracked":false}
          ]
        }
    })");
    assert(gitStatusEnvelope);
    const auto gitStatus = decodeGitStatus(*gitStatusEnvelope);
    assert(gitStatus && !gitStatus->repositoryRoot && gitStatus->changes.size() == 2);
    assert(!gitStatus->changes[0].originalPath);
    assert(gitStatus->changes[1].originalPath && *gitStatus->changes[1].originalPath == "README.old");

    const auto gitHistoryEnvelope = decodeCoreEnvelope(R"({
        "id":"req-7","ok":true,"data":{
          "references":[{"fullName":"refs/heads/main","shortName":"main","kind":"local","isCurrent":true,"upstreamShortName":null}],
          "commits":[{"hash":"abc","shortHash":"abc","parentHashes":[],"authorName":"A","authorEmail":"a@b",
                      "date":"2026/08/05 12:00","subject":"Initial","decorations":"HEAD -> main"}],
          "hasMore":false
        }
    })");
    assert(gitHistoryEnvelope);
    const auto history = decodeGitHistory(*gitHistoryEnvelope);
    assert(history && history->references.size() == 1 && history->commits.size() == 1);
    assert(history->references[0].isCurrent && history->commits[0].parentHashes.empty());

    const auto gitCommitEnvelope = decodeCoreEnvelope(R"({
        "id":"req-commit","ok":true,"data":{"commit":
          {"hash":"abc","shortHash":"abc","parentHashes":[],"authorName":"A",
           "authorEmail":"a@b","date":"2026/08/05 12:00","subject":"Initial","decorations":""}}
    })");
    const auto gitCommit = decodeGitCommit(*gitCommitEnvelope);
    assert(gitCommit && gitCommit->commit.hash == "abc");

    const auto gitComparisonEnvelope = decodeCoreEnvelope(
        R"({"id":"req-comparison","ok":true,"data":{"files":[{"status":"M","path":"a.txt"}]}})");
    const auto gitComparison = decodeGitComparison(*gitComparisonEnvelope);
    assert(gitComparison && gitComparison->files.size() == 1);

    const auto gitStashesEnvelope = decodeCoreEnvelope(R"({
        "id":"req-stash","ok":true,"data":{"stashes":[
          {"reference":"stash@{0}","message":"work","branch":null,"date":"2026-08-05"}
        ]}
    })");
    const auto gitStashes = decodeGitStashesResponse(*gitStashesEnvelope);
    assert(gitStashes && gitStashes->stashes.size() == 1 && !gitStashes->stashes[0].branch);

    const auto gitBlameResponseEnvelope = decodeCoreEnvelope(R"({
        "id":"req-blame","ok":true,"data":{"lines":[
          {"line":1,"commitHash":"000","authorName":"Unknown","authorTime":0}
        ]}
    })");
    const auto gitBlameResponse = decodeGitBlameResponse(*gitBlameResponseEnvelope);
    assert(gitBlameResponse && gitBlameResponse->lines.size() == 1);

    const auto gitCommandEnvelope = decodeCoreEnvelope(
        R"({"id":"req-8","ok":true,"data":{"output":"warning","exitCode":-128}})");
    assert(gitCommandEnvelope);
    const auto gitCommand = decodeGitCommand(*gitCommandEnvelope);
    assert(gitCommand && gitCommand->exitCode == -128 && !gitCommand->stashRestore);

    const auto gitStashRestoreEnvelope = decodeCoreEnvelope(R"({
        "id":"req-stash-restore","ok":true,"data":{
          "output":"conflicts","exitCode":1,
          "stashRestore":{"stashReference":"stash@{0}","conflictedPaths":["src/App.java"],"deferred":true}
        }
    })");
    const auto gitStashRestore = decodeGitCommand(*gitStashRestoreEnvelope);
    assert(gitStashRestore && gitStashRestore->stashRestore &&
           gitStashRestore->stashRestore->stashReference == "stash@{0}" &&
           gitStashRestore->stashRestore->conflictedPaths.size() == 1 &&
           gitStashRestore->stashRestore->deferred);

    const auto gitCheckoutPreflightEnvelope = decodeCoreEnvelope(
        R"({"id":"git-checkout","ok":true,"data":{"blockingPaths":["README.md"]}})");
    const auto gitCheckoutPreflight = decodeGitCheckoutPreflight(*gitCheckoutPreflightEnvelope);
    assert(gitCheckoutPreflight && gitCheckoutPreflight->blockingPaths ==
           std::vector<std::string>{"README.md"});

    const auto gitPullPreflightEnvelope = decodeCoreEnvelope(R"({
        "id":"git-pull","ok":true,"data":{"upstream":null,"ahead":2,"behind":3,
          "diverged":true,"hasLocalChanges":false}
    })");
    const auto gitPullPreflight = decodeGitPullPreflight(*gitPullPreflightEnvelope);
    assert(gitPullPreflight && !gitPullPreflight->upstream && gitPullPreflight->ahead == 2 &&
           gitPullPreflight->behind == 3 && gitPullPreflight->diverged &&
           !gitPullPreflight->hasLocalChanges);

    const auto gitIntegrationPreflightEnvelope = decodeCoreEnvelope(R"({
        "id":"git-integration","ok":true,"data":{
          "blockingPaths":["src/App.java"],"blocksEntirely":true}
    })");
    const auto gitIntegrationPreflight =
        decodeGitIntegrationPreflight(*gitIntegrationPreflightEnvelope);
    assert(gitIntegrationPreflight && gitIntegrationPreflight->blocksEntirely &&
           gitIntegrationPreflight->blockingPaths.size() == 1);

    const auto gitConflictMarkersEnvelope = decodeCoreEnvelope(
        R"({"id":"git-conflicts","ok":true,"data":{"paths":["src/App.java"]}})");
    const auto gitConflictMarkers = decodeGitConflictMarkers(*gitConflictMarkersEnvelope);
    assert(gitConflictMarkers && gitConflictMarkers->paths.size() == 1);

    const auto gitOperationStateEnvelope = decodeCoreEnvelope(R"({
        "id":"git-operation","ok":true,"data":{"kind":"rebase","reference":"main",
          "step":2,"total":5,"conflictedPaths":["src/App.java"],
          "autoStashReference":"stash@{2}"}
    })");
    const auto gitOperationState = decodeGitOperationState(*gitOperationStateEnvelope);
    assert(gitOperationState && gitOperationState->kind == "rebase" &&
           gitOperationState->reference == "main" && gitOperationState->step == 2 &&
           gitOperationState->total == 5 && gitOperationState->conflictedPaths.size() == 1 &&
           gitOperationState->autoStashReference == "stash@{2}");

    const auto idleGitOperationStateEnvelope = decodeCoreEnvelope(R"({
        "id":"git-operation-idle","ok":true,"data":{"kind":"","reference":null,
          "step":null,"total":null,"conflictedPaths":[]}
    })");
    const auto idleGitOperationState = decodeGitOperationState(*idleGitOperationStateEnvelope);
    assert(idleGitOperationState && !idleGitOperationState->reference &&
           !idleGitOperationState->step && !idleGitOperationState->total);

    const auto malformedGitOperationStateEnvelope = decodeCoreEnvelope(R"({
        "id":"git-operation-invalid","ok":true,"data":{"kind":"rebase",
          "reference":null,"step":"2","total":5,"conflictedPaths":[]}
    })");
    assert(!decodeGitOperationState(*malformedGitOperationStateEnvelope));

    const auto gitBlameEnvelope = decodeCoreEnvelope(R"({
        "id":"req-9","ok":true,"data":{"lines":[
          {"line":1,"commitHash":"000","authorName":"Unknown","authorTime":0}
        ]}
    })");
    assert(gitBlameEnvelope);
    const auto blame = decodeGitBlame(*gitBlameEnvelope);
    assert(blame && blame->front().line == 1 && blame->front().authorTime == 0);

    const auto nullData = decodeCoreEnvelope(R"({"id":"req-5","ok":true,"data":null})");
    assert(nullData && nullData->hasData && nullData->data.isNull());
    assert(!decodeWorkspaceSnapshot(*nullData));

    const auto historyRecordEnvelope = decodeCoreEnvelope(R"({
        "id":"history-1","ok":true,"data":{
          "id":"entry-1","timestamp":1720000000,"relativePath":"src/Main.java",
          "reason":"saved","contentPath":"src-Main.java/entry-1.snapshot","byteCount":42
        }
    })");
    assert(historyRecordEnvelope);
    const auto historyRecord = decodeHistoryRecord(*historyRecordEnvelope);
    assert(historyRecord && historyRecord->entry && historyRecord->entry->timestamp == 1720000000);
    assert(historyRecord->entry->relativePath == "src/Main.java");

    const auto historyNull = decodeHistoryRecord(*nullData);
    assert(historyNull && !historyNull->entry);

    const auto historyEntriesEnvelope = decodeCoreEnvelope(R"({
        "id":"history-2","ok":true,"data":{"entries":[
          {"id":"entry-1","timestamp":1720000000,"relativePath":"a.txt",
           "reason":"saved","contentPath":"a/entry-1.snapshot","byteCount":1}
        ]}
    })");
    assert(historyEntriesEnvelope);
    const auto historyEntries = decodeHistoryEntries(*historyEntriesEnvelope);
    assert(historyEntries && historyEntries->entries.size() == 1);

    const auto historyContentEnvelope = decodeCoreEnvelope(
        R"({"id":"history-3","ok":true,"data":{"text":"snapshot text"}})");
    const auto historyContent = decodeHistoryContent(*historyContentEnvelope);
    assert(historyContent && historyContent->text == "snapshot text");
    const auto historyRelocateEnvelope = decodeCoreEnvelope(
        R"({"id":"history-4","ok":true,"data":{"relocated":true}})");
    const auto historyRelocate = decodeHistoryRelocate(*historyRelocateEnvelope);
    assert(historyRelocate && historyRelocate->relocated);

    const auto mavenEnvelope = decodeCoreEnvelope(R"({
        "id":"maven-1","ok":true,"data":{
          "groupId":null,"artifactId":"app","version":"1.0","packaging":"pom",
          "modules":[{"relativePath":"module-a","groupId":"com.example",
            "artifactId":"module-a","version":null,"packaging":"jar","modules":[]}],
          "profiles":[{"id":"dev","isActiveByDefault":true}],"hasWrapper":true
        }
    })");
    assert(mavenEnvelope);
    const auto maven = decodeMavenScan(*mavenEnvelope);
    assert(maven && maven->scan && !maven->scan->groupId);
    assert(maven->scan->modules.size() == 1 && maven->scan->modules[0].version == std::nullopt);
    assert(maven->scan->profiles[0].isActiveByDefault && maven->scan->hasWrapper);
    const auto mavenNull = decodeMavenScan(*nullData);
    assert(mavenNull && !mavenNull->scan);

    const auto diagnosticsEnvelope = decodeCoreEnvelope(R"({
        "id":"maven-2","ok":true,"data":{"issues":[
          {"path":"src/Main.java","line":7,"column":null,"severity":"error","message":"bad"}
        ]}
    })");
    const auto diagnostics = decodeMavenDiagnostics(*diagnosticsEnvelope);
    assert(diagnostics && diagnostics->issues.size() == 1 && !diagnostics->issues[0].column);

    const auto javaRunEnvelope = decodeCoreEnvelope(R"({
        "id":"java-1","ok":true,"data":{
          "mainClasses":[{"path":"src/App.java","qualifiedName":"com.example.App",
            "simpleName":"App","isSpringBoot":true}],
          "configurations":[{"id":"spring:com.example.App","name":"App",
            "kind":"springBoot","modulePath":null,"mainClass":"com.example.App"}]
        }
    })");
    const auto javaRun = decodeJavaRunConfigurations(*javaRunEnvelope);
    assert(javaRun && javaRun->mainClasses.size() == 1 && javaRun->mainClasses[0].isSpringBoot);
    assert(javaRun->configurations[0].modulePath == std::nullopt);

    const auto javaVisionEnvelope = decodeCoreEnvelope(R"({
        "id":"java-2","ok":true,"data":{"hints":[
          {"line":0,"utf16Column":4,"symbol":"run","usageCount":3}
        ]}
    })");
    const auto javaVision = decodeJavaCodeVision(*javaVisionEnvelope);
    assert(javaVision && javaVision->hints[0].line == 0 &&
           javaVision->hints[0].utf16Column == 4);

    const auto javaClassNameEnvelope = decodeCoreEnvelope(
        R"({"id":"java-3","ok":true,"data":{"className":"com.example.App"}})");
    const auto javaClassName = decodeJavaClassName(*javaClassNameEnvelope);
    assert(javaClassName && javaClassName->className == "com.example.App");

    const auto javaDefinitionEnvelope = decodeCoreEnvelope(
        R"({"id":"java-4","ok":true,"data":{"line":12,"utf16Column":8}})");
    const auto javaDefinition = decodeJavaSourceDefinition(*javaDefinitionEnvelope);
    assert(javaDefinition && javaDefinition->definition &&
           javaDefinition->definition->line == 12);
    const auto javaDefinitionNull = decodeJavaSourceDefinition(*nullData);
    assert(javaDefinitionNull && !javaDefinitionNull->definition);

    const auto javaPortEnvelope = decodeCoreEnvelope(
        R"({"id":"java-5","ok":true,"data":{"port":null}})");
    const auto javaPort = decodeJavaServerPort(*javaPortEnvelope);
    assert(javaPort && !javaPort->port);

    const auto javaStructureEnvelope = decodeCoreEnvelope(R"({
        "id":"java-6","ok":true,"data":{
          "foldRegions":[{"kind":"method","startLine":1,"endLine":4,
            "hiddenStart":2,"hiddenLength":2}],
          "implementationMarkers":[{"line":5,"utf16Column":2,
            "implementationCount":1,"direction":"down"}],
          "inlayHints":[{"line":6,"utf16Column":10,"label":"String"}]
        }
    })");
    const auto javaStructure = decodeJavaStructure(*javaStructureEnvelope);
    assert(javaStructure && javaStructure->foldRegions.size() == 1 &&
           javaStructure->implementationMarkers[0].direction == "down" &&
           javaStructure->inlayHints[0].label == "String");

    const auto signedJson = serializeJson(JsonValue(std::int64_t{-7}));
    const auto unsignedJson = serializeJson(JsonValue(std::uint64_t{18446744073709551615ULL}));
    const auto floatingJson = serializeJson(JsonValue(1.25));
    const auto escapedJson = serializeJson(JsonValue("line\n\"quote\""));
    assert(signedJson == "-7");
    assert(unsignedJson == "18446744073709551615");
    assert(floatingJson == "1.25");
    assert(escapedJson == "\"line\\n\\\"quote\\\"\"");
    assert(parseJson(unsignedJson).succeeded());

    const auto searchRequest = parseJson(encodeSearchRequest(SearchRequestDto{
        "/tmp/project", "foo\"bar", true, false, true, 20, std::nullopt, 4, std::nullopt,
        "*.java", {".git"}, {"*.class"}
    }));
    assert(searchRequest.succeeded());
    assert(*objectValue(*searchRequest.value, "query")->asString() == "foo\"bar");
    assert(*objectValue(*searchRequest.value, "maxContentResults")->asUInt() == 4);
    assert(objectValue(*searchRequest.value, "maxFileResults") == nullptr);

    const auto markdownRequest = parseJson(encodeMarkdownRenderRequest(
        MarkdownRenderRequestDto{"# Preview"}));
    assert(markdownRequest.succeeded());
    assert(*objectValue(*markdownRequest.value, "source")->asString() == "# Preview");

    const auto historyRequest = parseJson(encodeHistoryRecordRequest(HistoryRecordRequestDto{
        "/workspace", "/state", "src/Main.java", "saved", std::nullopt, true, {}, {}
    }));
    assert(historyRequest.succeeded());
    assert(objectValue(*historyRequest.value, "content") == nullptr);
    assert(*objectValue(*historyRequest.value, "pruneExpired")->asBool());

    const auto javaRequest = parseJson(encodeJavaSourceDefinitionRequest(
        JavaSourceDefinitionRequestDto{"class App {}", "App", std::string("run")}));
    assert(javaRequest.succeeded());
    assert(*objectValue(*javaRequest.value, "declarationName")->asString() == "App");
    assert(*objectValue(*javaRequest.value, "memberName")->asString() == "run");

    const auto mavenRequest = parseJson(encodeMavenDiagnosticsRequest(
        MavenDiagnosticsRequestDto{"/workspace", "[ERROR] src/App.java:[4,2] bad"}));
    assert(mavenRequest.succeeded());
    assert(*objectValue(*mavenRequest.value, "output")->asString() ==
           "[ERROR] src/App.java:[4,2] bad");

    const auto gitWriteRequest = parseJson(encodeGitWriteRequest(GitWriteRequestDto{
        "/workspace", "stage", {"src/Main.java"}, std::string("main"), std::nullopt,
        std::nullopt, std::nullopt, std::nullopt, std::nullopt, std::nullopt,
        std::nullopt, false, false, false, true, true
    }));
    assert(gitWriteRequest.succeeded());
    assert(*objectValue(*gitWriteRequest.value, "operation")->asString() == "stage");
    assert(*objectValue(*gitWriteRequest.value, "reference")->asString() == "main");
    assert(objectValue(*gitWriteRequest.value, "message") == nullptr);
    assert(*objectValue(*gitWriteRequest.value, "force")->asBool());
    assert(*objectValue(*gitWriteRequest.value, "autoStash")->asBool());

    const auto gitCheckoutPreflightRequest = parseJson(encodeGitCheckoutPreflightRequest(
        GitCheckoutPreflightRequestDto{"/workspace", "feature"}));
    assert(gitCheckoutPreflightRequest.succeeded());
    assert(*objectValue(*gitCheckoutPreflightRequest.value, "reference")->asString() ==
           "feature");

    const auto gitPullPreflightRequest = parseJson(
        encodeGitPullPreflightRequest(GitPullPreflightRequestDto{"/workspace"}));
    assert(gitPullPreflightRequest.succeeded());
    assert(*objectValue(*gitPullPreflightRequest.value, "root")->asString() == "/workspace");

    const auto gitIntegrationPreflightRequest = parseJson(encodeGitIntegrationPreflightRequest(
        GitIntegrationPreflightRequestDto{"/workspace", "feature", "rebase"}));
    assert(gitIntegrationPreflightRequest.succeeded());
    assert(*objectValue(*gitIntegrationPreflightRequest.value, "operation")->asString() ==
           "rebase");

    const auto gitConflictMarkersRequest = parseJson(
        encodeGitConflictMarkersRequest(GitConflictMarkersRequestDto{"/workspace"}));
    const auto gitOperationStateRequest = parseJson(
        encodeGitOperationStateRequest(GitOperationStateRequestDto{"/workspace"}));
    assert(gitConflictMarkersRequest.succeeded() && gitOperationStateRequest.succeeded());

    const auto gitDiffRequest = parseJson(encodeGitDiffRequest(GitDiffRequestDto{
        "/workspace", {"src/Main.java"}, std::nullopt, std::nullopt,
        false, false, 80, true
    }));
    assert(gitDiffRequest.succeeded());
    assert(*objectValue(*gitDiffRequest.value, "contextLines")->asUInt() == 80);
    assert(*objectValue(*gitDiffRequest.value, "ignoreAllWhitespace")->asBool());

    const auto gitShelfPatchesRequest = parseJson(encodeGitShelfPatchesRequest(
        GitShelfPatchesRequestDto{"/workspace"}));
    assert(gitShelfPatchesRequest.succeeded());
    assert(*objectValue(*gitShelfPatchesRequest.value, "root")->asString() == "/workspace");
    const auto gitShelfCleanRequest = parseJson(encodeGitShelfCleanRequest(
        GitShelfCleanRequestDto{"/workspace", "staged", "working"}));
    assert(gitShelfCleanRequest.succeeded());
    assert(*objectValue(*gitShelfCleanRequest.value, "stagedPatch")->asString() == "staged");
    assert(*objectValue(*gitShelfCleanRequest.value, "workingTreePatch")->asString() == "working");

    const auto shelfRequest = parseJson(encodeShelfCreateRequest(ShelfCreateRequestDto{
        "/workspace", "/state", "before checkout", "staged", "working"}));
    assert(shelfRequest.succeeded());
    assert(*objectValue(*shelfRequest.value, "stagedPatch")->asString() == "staged");
    assert(*objectValue(*shelfRequest.value, "workingTreePatch")->asString() == "working");
    const auto shelfEnvelope = decodeCoreEnvelope(R"({
        "id":"shelf","ok":true,"data":{
          "id":"shelf-1","workspaceRoot":"/workspace","label":"before checkout",
          "createdAt":1720000000000,"stagedByteCount":6,"workingTreeByteCount":7
        }
    })");
    const auto shelf = decodeShelfCreate(*shelfEnvelope);
    assert(shelf && shelf->shelf.id == "shelf-1" && shelf->shelf.stagedByteCount == 6);
    const auto restoreEnvelope = decodeCoreEnvelope(R"({
        "id":"restore","ok":true,"data":{
          "id":"shelf-1","stagedPatch":"staged","workingTreePatch":"working"
        }
    })");
    const auto restoredShelf = decodeShelfRestore(*restoreEnvelope);
    assert(restoredShelf && restoredShelf->stagedPatch == "staged" &&
           restoredShelf->workingTreePatch == "working");
    return 0;
}
