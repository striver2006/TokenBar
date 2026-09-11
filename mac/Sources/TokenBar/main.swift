import Cocoa

// 单实例守卫要赶在任何 UI 建立之前：第二个实例不闪菜单栏图标、不发定时器
if !SingleInstanceGuard.tryBecomeOnlyInstance() {
    SingleInstanceGuard.activateExistingInstance()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
