//! 可复用的搜索输入框：Linux 工作台唯一的文本输入实现。
//!
//! 背景：早期多个弹窗（文件树过滤、快速打开、命令面板、跳转到行、全局搜索、
//! 分支管理器）各自用普通 `div` + `on_key_down` 手动拼接 `key_char` 来实现
//! “输入框”。这种自绘输入没有注册 GPUI 的 input handler，导致：
//! - 中文输入法（XIM/ibus）的提交/预编辑事件无处落地，打不出汉字；
//! - `Ctrl+V` 粘贴、选区、光标移动都不支持；
//! - 每个弹窗都要重复写一遍同一套按键分支，规则容易漂移。
//!
//! 现在统一接入本模块：用 gpui-kit 官方的 `Input`/`InputState` 组件，由组件
//! 负责 IME 组字、剪贴板、选区与光标；各弹窗只关心业务事件。
//!
//! 使用方式：
//! ```ignore
//! let search = SearchInput::new(placeholder, window, cx);
//! let subscription = search.subscribe(cx, |this, event, cx| match event {
//!     InputEvent::Change => { /* 读取 search.value(cx) */ }
//!     InputEvent::PressEnter { shift, .. } => { /* 回车 / Shift+回车 */ }
//!     _ => {}
//! });
//! // render 时：.child(search.element())
//! ```
//!
//! 关键约束（务必遵守）：**不要在 `Render::render` 里每帧调用
//! `window.focus(&owner.root_focus_handle)`**。那样会把焦点从搜索框手里夺走，
//! 造成“点得进去却打不出字”。打开弹窗时只聚焦一次即可（见
//! [`SearchInput::focus`]）。

use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::Sizable as _;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    div, AppContext as _, Context, IntoElement, ParentElement as _, Styled as _, Subscription,
    Window,
};

/// 可复用的搜索输入框：持有输入状态与其事件订阅。
pub struct SearchInput {
    state: gpui_kit::Entity<InputState>,
    /// 是否使用紧凑尺寸（内嵌在低矮行里，如侧边栏过滤条）。
    compact: bool,
}

impl SearchInput {
    /// 新建搜索输入（带占位文案）。`placeholder` 会被解析为 owned 字符串。
    pub fn new(
        placeholder: impl Into<gpui_kit::SharedString>,
        window: &mut Window,
        cx: &mut gpui_kit::App,
    ) -> Self {
        let placeholder = placeholder.into();
        let state = cx.new(|cx| InputState::new(window, cx).placeholder(placeholder));
        Self {
            state,
            compact: false,
        }
    }

    /// 使用紧凑尺寸（对应 `Input::small()`）。
    pub fn compact(mut self) -> Self {
        self.compact = true;
        self
    }

    /// 读取当前文本。
    pub fn value(&self, cx: &gpui_kit::App) -> String {
        self.state.read(cx).value().to_string()
    }

    /// 设置文本并清空撤销历史（打开弹窗复位、清空按钮时使用）。
    pub fn set_value(
        &self,
        value: impl Into<gpui_kit::SharedString>,
        window: &mut Window,
        cx: &mut gpui_kit::App,
    ) {
        let value = value.into();
        self.state
            .update(cx, |state, cx| state.set_value(value, window, cx));
    }

    /// 聚焦搜索框。弹窗打开时调用**一次**；不要在 render 里每帧调用根节点聚焦。
    pub fn focus(&self, window: &mut Window, cx: &mut gpui_kit::App) {
        self.state.update(cx, |state, cx| state.focus(window, cx));
    }

    /// 更新占位文案（切换分区等场景）。
    pub fn set_placeholder(
        &self,
        placeholder: impl Into<gpui_kit::SharedString>,
        window: &mut Window,
        cx: &mut gpui_kit::App,
    ) {
        let placeholder = placeholder.into();
        self.state.update(cx, |state, cx| {
            state.set_placeholder(placeholder, window, cx)
        });
    }

    /// 在 owner 上订阅输入事件，把原始 [`InputEvent`] 转交 owner 处理。
    ///
    /// 返回的 [`Subscription`] 必须由 owner 持有其生命周期（保存到字段），
    /// 否则订阅会立即失效。
    pub fn subscribe<Owner, F>(&self, cx: &mut Context<Owner>, handler: F) -> Subscription
    where
        Owner: 'static,
        F: Fn(&mut Owner, &InputEvent, &mut Context<Owner>) + 'static,
    {
        cx.subscribe(
            &self.state,
            move |owner: &mut Owner, _, event: &InputEvent, cx| {
                handler(owner, event, cx);
            },
        )
    }

    /// 渲染统一外观的搜索输入框主体（`appearance(false)`：关闭组件自带背景/
    /// 边框/焦点环，交由调用方的行容器决定外观，避免多出一层阴影或双边框）。
    pub fn element(&self) -> impl IntoElement {
        div().flex_1().min_w_0().child(
            Input::new(&self.state)
                .when(self.compact, |input| input.small())
                .appearance(false),
        )
    }
}
