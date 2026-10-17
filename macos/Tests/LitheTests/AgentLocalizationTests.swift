import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite("Agent interface localization", .serialized)
struct AgentLocalizationTests {
    private func resources() throws -> Bundle {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        return try #require(Bundle(url: root))
    }

    @Test func productCopyFollowsInterfaceLocaleAndHistoryRemainsVerbatim() throws {
        let bundle = try resources()
        for (key, chinese) in [
            ("The Agent process starts when this panel opens.", "打开此面板时才会启动 Agent 进程。"),
            ("Starting the Agent…", "正在启动 Agent…"),
            ("Preparing conversation…", "正在准备对话…"),
            ("Sending…", "发送中…"),
            ("Agent received", "Agent 已接收"),
            ("Supplementary message cancelled.", "补充消息已取消。"),
            ("The Agent did not accept the supplementary message.", "Agent 未接受补充消息。"),
            ("%@ · %@ / %@ context used", "%@ · %@ / %@ 上下文已使用"),
            ("Context usage", "上下文用量"),
            ("Breakdown unavailable", "分项暂不可用"),
            ("Turn on Model call statistics, reconnect and send a message to see the breakdown.", "开启“模型调用统计”，重新连接并发送消息后可查看分项。")
        ] {
            #expect(AgentLocalization.string(String.LocalizationValue(key), locale: Locale(identifier: "en"), bundle: bundle) == key)
            #expect(AgentLocalization.string(String.LocalizationValue(key), locale: Locale(identifier: "en-US"), bundle: bundle) == key)
            #expect(AgentLocalization.string(String.LocalizationValue(key), locale: Locale(identifier: "zh-Hans"), bundle: bundle) == chinese)
        }
        let notice = "Cannot create a new conversation: " + AgentConversationError.notConnected.localizedDescription
        #expect(AgentLocalization.message(notice, locale: Locale(identifier: "en"), bundle: bundle) == notice)
        #expect(AgentLocalization.message(notice, locale: Locale(identifier: "zh-Hans"), bundle: bundle) != notice)
        #expect(AgentLocalization.message("server diagnostic / 中文文件.swift", locale: Locale(identifier: "en"), bundle: bundle)
            == "server diagnostic / 中文文件.swift")
        let session = AgentSessionSummary(id: "history", title: "中文历史对话")
        #expect(AgentHistoryPresentation.popupTitle(session, metadata: nil, conversation: nil,
                                                   locale: Locale(identifier: "en")) == "中文历史对话")
        #expect(AgentHistoryPresentation.popupTitle(session, metadata: .init(title: "我的名称"), conversation: nil,
                                                   locale: Locale(identifier: "en")) == "我的名称")
        #expect(AgentConversationError.notConnected.errorDescription == "The Agent is not running. Connect to start a conversation.")
    }

    @Test func startupUsesSharedTypographyInBothLanguagesAndThemes() throws {
        let bundle = try resources()
        for language in ["en", "zh-Hans"] {
            for scheme in [ColorScheme.dark, .light] {
                let host = NSHostingView(rootView: AgentEmptyStateView(systemImage: "sparkles", title: "Starting the Agent…",
                    message: "The Agent process starts when this panel opens.", isBusy: true, bundle: bundle)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
                    .background(LitheTheme.editor))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_LOCALE_SCREENSHOTS"] {
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: folder).appendingPathComponent("startup-\(language)-\(scheme).png"))
                }
                #expect(host.fittingSize.width <= 400)
            }
        }
    }
}
