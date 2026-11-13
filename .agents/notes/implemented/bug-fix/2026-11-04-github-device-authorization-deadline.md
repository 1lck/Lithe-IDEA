# Agent 笔记：GitHub 设备授权的等待与截止时间

状态：已实现

## 先说结论

GitHub 设备授权的下一步、退避间隔和过期判定由 Core 计算，平台只提供单调时间、等待和网络请求。每次等待结束后都重新检查期限，授权过期后不能再轮询；GitHub 已确认的授权响应即使因网络延迟跨过本地期限也仍然有效。

## 问题

旧实现把轮询规则留在 Swift 中，只在等待之前检查期限，因此长间隔可能在授权过期后仍发出请求。它还把间隔限制在 60 秒，收到更多 `slow_down` 时不能继续增加等待，与 GitHub 和 OAuth 设备授权要求不同。

## 决策

平台用在系统休眠期间也前进的单调时钟报告自设备码请求发出以来的毫秒数，不把设备码或令牌放入状态转换请求。计时包含网络往返和展示验证码的时间，避免把已经消耗的有效期重新计算。Core 根据服务端状态返回等待、请求或终止动作；等待最多到本地截止时间，服务端的 `slow_down` 会在之后的每次轮询继续生效。最大间隔只限制到授权允许的最长生命周期：达到该值后不会再发请求，因此不会提前轮询。

正确做法：等待完成后先重新请求 Core 判断，再决定是否发起网络请求。不要在收到 `slow_down` 后把间隔固定在 60 秒，也不要因为网络响应比截止时间晚到而丢弃服务端已经批准的令牌。

## 考虑过的备选方案

保留 Swift 计时和 60 秒退避上限只需少量修改，但未来 Windows 会再次实现状态规则，且上限会使请求快于服务端允许的速度。让 Core 持有真实时钟和网络会使测试依赖系统时间与网络，也会越过平台职责边界。

## 后果

状态转换增加少量本地桥接调用，但请求和响应不包含凭据，等待不产生空闲轮询。预览遵守最多一天的既有授权生命周期约束；极长的服务端轮询间隔可能导致本次授权直接过期，而不会提前请求。

## 验证

`Lithe-core-rust/rust/fixtures/github/device-authorization-transition-v1.json` 由 Core 和 Swift 桥接测试共同验证。`GitHubServiceTests/deviceFlowSlowDown`、`deviceFlowDeadline` 和 `deviceFlowDisplayedTooLong` 用可控时钟检查完整服务流程，无需真实等待或网络。

## 适用范围

`rust/crates/core/src/github/mod.rs`、`macos/Sources/Lithe/Services/GitHub/GitHubService.swift` 和未来接入设备授权的 Windows 适配器。
