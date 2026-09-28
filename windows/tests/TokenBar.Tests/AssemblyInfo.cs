using Xunit;

// LocalizationManager 是全局单例，WindowTitleTests 会在用例内切换界面语言；
// 关闭 xUnit 默认的集合间并行，避免语言切换与其他用例的 IsChinese 读取发生竞态（CI 上偶发假红）。
[assembly: CollectionBehavior(DisableTestParallelization = true)]
