using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace TokenBar.Helpers
{
    /// <summary>
    /// 为 WPF TextBox 提供占位符（水印）支持：文本为空且未聚焦时显示灰色提示文字。
    /// 用法：TextBoxWatermark.SetPlaceholder(TxtKey, "sk-... or sk-proj-...")。
    /// </summary>
    public static class TextBoxWatermark
    {
        public static readonly DependencyProperty PlaceholderProperty =
            DependencyProperty.RegisterAttached(
                "Placeholder",
                typeof(string),
                typeof(TextBoxWatermark),
                new PropertyMetadata(string.Empty, OnPlaceholderChanged));

        public static string GetPlaceholder(TextBox box) => (string)box.GetValue(PlaceholderProperty);

        public static void SetPlaceholder(TextBox box, string value) => box.SetValue(PlaceholderProperty, value);

        private static void OnPlaceholderChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            if (d is not TextBox box) return;

            // 语言切换会重复调用 SetPlaceholder，先解绑避免事件重复订阅
            box.TextChanged -= OnTextChanged;
            box.GotKeyboardFocus -= OnFocusChanged;
            box.LostKeyboardFocus -= OnFocusChanged;
            box.Unloaded -= OnBoxUnloaded;

            var hasPlaceholder = e.NewValue is string text && !string.IsNullOrEmpty(text);
            if (hasPlaceholder)
            {
                box.TextChanged += OnTextChanged;
                box.GotKeyboardFocus += OnFocusChanged;
                box.LostKeyboardFocus += OnFocusChanged;
                box.Unloaded += OnBoxUnloaded;
            }

            UpdateAdorner(box);
        }

        private static void OnTextChanged(object sender, TextChangedEventArgs e)
        {
            if (sender is TextBox box) UpdateAdorner(box);
        }

        private static void OnFocusChanged(object sender, KeyboardFocusChangedEventArgs e)
        {
            if (sender is TextBox box) UpdateAdorner(box);
        }

        private static void OnBoxUnloaded(object sender, RoutedEventArgs e)
        {
            if (sender is not TextBox box) return;
            RemoveAdorner(box);
            // 控件重新加载后（如窗口复用）重建水印
            box.Loaded -= OnBoxLoadedRetry;
            box.Loaded += OnBoxLoadedRetry;
        }

        private static void OnBoxLoadedRetry(object sender, RoutedEventArgs e)
        {
            if (sender is TextBox box)
            {
                box.Loaded -= OnBoxLoadedRetry;
                UpdateAdorner(box);
            }
        }

        private static void UpdateAdorner(TextBox box)
        {
            var placeholder = GetPlaceholder(box);
            var show = !string.IsNullOrEmpty(placeholder) &&
                       string.IsNullOrEmpty(box.Text) &&
                       !box.IsKeyboardFocusWithin;

            var layer = AdornerLayer.GetAdornerLayer(box);
            if (layer == null)
            {
                // 控件尚未进入可视化树，加载完成后再补画
                if (!box.IsLoaded)
                {
                    box.Loaded -= OnBoxLoadedRetry;
                    box.Loaded += OnBoxLoadedRetry;
                }
                return;
            }

            var existing = layer.GetAdorners(box)?.OfType<WatermarkAdorner>().FirstOrDefault();
            if (show)
            {
                if (existing == null)
                {
                    layer.Add(new WatermarkAdorner(box, placeholder));
                }
                else
                {
                    existing.SetText(placeholder);
                }
            }
            else if (existing != null)
            {
                layer.Remove(existing);
            }
        }

        private static void RemoveAdorner(TextBox box)
        {
            var layer = AdornerLayer.GetAdornerLayer(box);
            if (layer == null) return;
            var adorners = layer.GetAdorners(box)?.OfType<WatermarkAdorner>().ToArray();
            if (adorners == null) return;
            foreach (var adorner in adorners)
            {
                layer.Remove(adorner);
            }
        }

        private sealed class WatermarkAdorner : Adorner
        {
            private readonly TextBox _box;
            private readonly TextBlock _hint;

            public WatermarkAdorner(TextBox box, string placeholder) : base(box)
            {
                _box = box;
                _hint = new TextBlock
                {
                    Text = placeholder,
                    Foreground = new SolidColorBrush(Color.FromRgb(156, 163, 175)), // #9CA3AF
                    FontSize = box.FontSize,
                    IsHitTestVisible = false
                };
                AddVisualChild(_hint);
            }

            public void SetText(string placeholder) => _hint.Text = placeholder;

            protected override int VisualChildrenCount => 1;

            protected override Visual GetVisualChild(int index) => _hint;

            protected override Size MeasureOverride(Size constraint)
            {
                _hint.Measure(constraint);
                return base.MeasureOverride(constraint);
            }

            protected override Size ArrangeOverride(Size finalSize)
            {
                var x = _box.Padding.Left + 2;
                var y = (finalSize.Height - _hint.DesiredSize.Height) / 2;
                _hint.Arrange(new Rect(new Point(x, Math.Max(0, y)), new Size(finalSize.Width - x, _hint.DesiredSize.Height)));
                return finalSize;
            }
        }
    }
}
