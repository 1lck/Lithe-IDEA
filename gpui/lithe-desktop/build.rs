//! Windows 可执行文件资源。
//!
//! Windows 任务栏和窗口左上角读取的是 exe 内嵌的 `RT_GROUP_ICON`，不是
//! GPUI 的 `WindowOptions`（`icon` 字段只对 X11 生效）。这里把 Tauri 打包
//! 使用的同一份 `icon.ico` 写进 lithe-desktop.exe，保证两个平台的任务栏
//! 图标逐字节一致。

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!(
        "cargo:rerun-if-changed=../../windows/tauri/src-tauri/icons/icon.ico"
    );

    // 构建脚本本身在宿主上运行，必须读目标平台而不是 `cfg!(windows)`。
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }

    // Windows MSVC 默认主线程栈只有 1MB；大型 GUI 在 Debug 模式递归排版
    // 提交历史树时极易爆栈。设置 8MB 栈空间对齐现代化桌面应用标准。
    println!("cargo:rustc-link-arg=/STACK:8388608");

    let mut resource = winresource::WindowsResource::new();
    resource.set_icon("../../windows/tauri/src-tauri/icons/icon.ico");
    resource
        .compile()
        .expect("failed to embed the Windows application icon");
}
