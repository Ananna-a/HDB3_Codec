// MainWindow.xaml.cs — 主窗口代码后置
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace HDB3_App
{
    public partial class MainWindow : Window
    {
        private bool _logExpanded = true;

        public MainWindow()
        {
            InitializeComponent();
        }

        private void ToggleLogPanel(object sender, MouseButtonEventArgs e)
        {
            _logExpanded = !_logExpanded;
            LogBox.Visibility = _logExpanded ? Visibility.Visible : Visibility.Collapsed;
            LogArrow.Text = _logExpanded ? "\u25B8" : "\u25B4";
        }
    }
}
