using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using RunnerForge.ViewModels;

namespace RunnerForge.Views;

public partial class LogsPage : UserControl
{
    public LogsPage() => InitializeComponent();

    private LogsViewModel? ViewModel => DataContext as LogsViewModel;

    private void OnCopyClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is null) return;
        // Already redacted by the LogBus, so this is safe to put on the clipboard.
        Clipboard.SetText(ViewModel.CopyText());
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is null) return;

        var dialog = new SaveFileDialog
        {
            FileName = $"runnerforge-{DateTime.Now:yyyyMMdd-HHmmss}.log",
            Filter = "Log files (*.log)|*.log|All files (*.*)|*.*",
        };

        if (dialog.ShowDialog() == true) ViewModel.SaveTo(dialog.FileName);
    }
}
