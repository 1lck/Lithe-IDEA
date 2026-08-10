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
           "replacementText":"bar"}
        ]}
    })");
    const auto replacement = decodeReplacementPreview(*replacementEnvelope);
    assert(replacement && replacement->files.size() == 1 &&
           replacement->files[0].matches[0].occurrenceCount == 2);

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

    const auto gitCommandWithStashEnvelope = decodeCoreEnvelope(R"({
        "id":"req-8b","ok":true,"data":{
          "output":"conflict","exitCode":1,
          "stashRestore":{"stashReference":"stash@{0}","conflictedPaths":["conflict.txt"]}
        }
    })");
    assert(gitCommandWithStashEnvelope);
    const auto gitCommandWithStash = decodeGitCommand(*gitCommandWithStashEnvelope);
    assert(gitCommandWithStash && gitCommandWithStash->stashRestore &&
           gitCommandWithStash->stashRestore->stashReference == "stash@{0}" &&
           gitCommandWithStash->stashRestore->conflictedPaths.size() == 1);

    const auto gitCommandNullStashEnvelope = decodeCoreEnvelope(
        R"({"id":"req-8c","ok":true,"data":{"output":"ok","exitCode":0,"stashRestore":null}})");
    assert(gitCommandNullStashEnvelope);
    const auto gitCommandNullStash = decodeGitCommand(*gitCommandNullStashEnvelope);
    assert(gitCommandNullStash && !gitCommandNullStash->stashRestore);

    const auto checkoutPreflightEnvelope = decodeCoreEnvelope(
        R"({"id":"preflight-1","ok":true,"data":{"blockingPaths":["conflict.txt"]}})");
    assert(checkoutPreflightEnvelope);
    const auto checkoutPreflight = decodeGitCheckoutPreflight(*checkoutPreflightEnvelope);
    assert(checkoutPreflight && checkoutPreflight->blockingPaths.size() == 1 &&
           checkoutPreflight->blockingPaths[0] == "conflict.txt");

    const auto conflictMarkersEnvelope = decodeCoreEnvelope(
        R"({"id":"preflight-2","ok":true,"data":{"paths":["src/Main.java"]}})");
    assert(conflictMarkersEnvelope);
    const auto conflictMarkers = decodeGitConflictMarkers(*conflictMarkersEnvelope);
    assert(conflictMarkers && conflictMarkers->paths.size() == 1);

    const auto integrationPreflightEnvelope = decodeCoreEnvelope(R"({
        "id":"preflight-3","ok":true,"data":{"blockingPaths":["a.txt"],"blocksEntirely":true}
    })");
    assert(integrationPreflightEnvelope);
    const auto integrationPreflight = decodeGitIntegrationPreflight(*integrationPreflightEnvelope);
    assert(integrationPreflight && integrationPreflight->blocksEntirely &&
           integrationPreflight->blockingPaths.size() == 1);

    const auto pullPreflightEnvelope = decodeCoreEnvelope(R"({
        "id":"preflight-4","ok":true,"data":{
          "upstream":"origin/main","ahead":1,"behind":2,"diverged":true,"hasLocalChanges":false
        }
    })");
    assert(pullPreflightEnvelope);
    const auto pullPreflight = decodeGitPullPreflight(*pullPreflightEnvelope);
    assert(pullPreflight && pullPreflight->upstream && *pullPreflight->upstream == "origin/main" &&
           pullPreflight->ahead == 1 && pullPreflight->behind == 2 && pullPreflight->diverged &&
           !pullPreflight->hasLocalChanges);

    const auto pullPreflightNullUpstreamEnvelope = decodeCoreEnvelope(R"({
        "id":"preflight-5","ok":true,"data":{
          "upstream":null,"ahead":0,"behind":0,"diverged":false,"hasLocalChanges":true
        }
    })");
    assert(pullPreflightNullUpstreamEnvelope);
    const auto pullPreflightNullUpstream = decodeGitPullPreflight(*pullPreflightNullUpstreamEnvelope);
    assert(pullPreflightNullUpstream && !pullPreflightNullUpstream->upstream &&
           pullPreflightNullUpstream->hasLocalChanges);

    const auto operationStateIdleEnvelope = decodeCoreEnvelope(R"({
        "id":"op-1","ok":true,"data":{
          "kind":"","reference":null,"step":null,"total":null,"conflictedPaths":[]
        }
    })");
    assert(operationStateIdleEnvelope);
    const auto operationStateIdle = decodeGitOperationState(*operationStateIdleEnvelope);
    assert(operationStateIdle && operationStateIdle->kind.empty() && !operationStateIdle->reference &&
           !operationStateIdle->step && !operationStateIdle->total &&
           operationStateIdle->conflictedPaths.empty());

    const auto operationStateRebaseEnvelope = decodeCoreEnvelope(R"({
        "id":"op-2","ok":true,"data":{
          "kind":"rebase","reference":"refs/heads/feature","step":2,"total":5,
          "conflictedPaths":["conflict.txt"]
        }
    })");
    assert(operationStateRebaseEnvelope);
    const auto operationStateRebase = decodeGitOperationState(*operationStateRebaseEnvelope);
    assert(operationStateRebase && operationStateRebase->kind == "rebase" &&
           operationStateRebase->reference && *operationStateRebase->reference == "refs/heads/feature" &&
           operationStateRebase->step && *operationStateRebase->step == 2 &&
           operationStateRebase->total && *operationStateRebase->total == 5 &&
           operationStateRebase->conflictedPaths.size() == 1);

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
    const auto expectedEscapedJson = R"("line\n\"quote\"")";
    assert(escapedJson == expectedEscapedJson);
    assert(parseJson(unsignedJson).succeeded());

    const auto searchRequest = parseJson(encodeSearchRequest(SearchRequestDto{
        "/tmp/project", "foo\"bar", true, false, true, 20, std::nullopt, 4, std::nullopt,
        "*.java", {".git"}, {"*.class"}
    }));
    assert(searchRequest.succeeded());
    assert(*objectValue(*searchRequest.value, "query")->asString() == "foo\"bar");
    assert(*objectValue(*searchRequest.value, "maxContentResults")->asUInt() == 4);
    assert(objectValue(*searchRequest.value, "maxFileResults") == nullptr);

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
        std::nullopt, false, false, false, false, false
    }));
    assert(gitWriteRequest.succeeded());
    assert(*objectValue(*gitWriteRequest.value, "operation")->asString() == "stage");
    assert(*objectValue(*gitWriteRequest.value, "reference")->asString() == "main");
    assert(objectValue(*gitWriteRequest.value, "message") == nullptr);
    assert(!*objectValue(*gitWriteRequest.value, "force")->asBool());
    assert(!*objectValue(*gitWriteRequest.value, "autoStash")->asBool());

    const auto gitWriteForceRequest = parseJson(encodeGitWriteRequest(GitWriteRequestDto{
        "/workspace", "checkout", {}, std::string("refs/heads/main"),
        std::string("local"), std::nullopt, std::nullopt, std::nullopt, std::nullopt,
        std::nullopt, std::nullopt, false, false, false, true, true
    }));
    assert(gitWriteForceRequest.succeeded());
    assert(*objectValue(*gitWriteForceRequest.value, "force")->asBool());
    assert(*objectValue(*gitWriteForceRequest.value, "autoStash")->asBool());

    const auto checkoutPreflightRequest = parseJson(encodeGitCheckoutPreflightRequest(
        GitCheckoutPreflightRequestDto{"/workspace", "refs/heads/main"}));
    assert(checkoutPreflightRequest.succeeded());
    assert(*objectValue(*checkoutPreflightRequest.value, "reference")->asString() ==
           "refs/heads/main");

    const auto conflictMarkersRequest = parseJson(encodeGitConflictMarkersRequest(
        GitConflictMarkersRequestDto{"/workspace"}));
    assert(conflictMarkersRequest.succeeded());
    assert(*objectValue(*conflictMarkersRequest.value, "root")->asString() == "/workspace");

    const auto integrationPreflightRequest = parseJson(encodeGitIntegrationPreflightRequest(
        GitIntegrationPreflightRequestDto{"/workspace", "refs/heads/feature", "merge"}));
    assert(integrationPreflightRequest.succeeded());
    assert(*objectValue(*integrationPreflightRequest.value, "operation")->asString() == "merge");

    const auto pullPreflightRequest = parseJson(encodeGitPullPreflightRequest(
        GitPullPreflightRequestDto{"/workspace"}));
    assert(pullPreflightRequest.succeeded());

    const auto operationStateRequest = parseJson(encodeGitOperationStateRequest(
        GitOperationStateRequestDto{"/workspace"}));
    assert(operationStateRequest.succeeded());

    const auto gitDiffRequest = parseJson(encodeGitDiffRequest(GitDiffRequestDto{
        "/workspace", {"src/Main.java"}, std::nullopt, std::nullopt,
        false, false, 80, true
    }));
    assert(gitDiffRequest.succeeded());
    assert(*objectValue(*gitDiffRequest.value, "contextLines")->asUInt() == 80);
    assert(*objectValue(*gitDiffRequest.value, "ignoreAllWhitespace")->asBool());
    return 0;
}
