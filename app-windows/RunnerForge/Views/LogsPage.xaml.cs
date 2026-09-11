using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using RunnerForge.ViewModels;

namespace RunnerForge.Views;

public partial class LogsPage : UserControl
{
    public LogsPage() => InitializeComponent();

    private LogsViewModel? ViewModel => DataContext as LogsViewModel;

    // -----------------------------------------------------------------------
    // Copying to the clipboard is not a safe operation, and this is the page
    // people use precisely when something has already gone wrong.
    //
    // The Windows clipboard is a single system-wide resource opened exclusively.
    // Any other process holding it — a clipboard manager, a remote desktop
    // client, Office, a screenshot tool — makes SetText throw
    // CLIPBRD_E_CANT_OPEN (0x800401D0). It is transient and common, and it is
    // exactly what happened here:
    //
    //   System.Runtime.InteropServices.COMException (0x800401D0):
    //     OpenClipboard failed
    //       at System.Windows.Clipboard.Flush()
    //       at RunnerForge.Views.LogsPage.OnCopyClick(...)
    //
    // Retrying briefly resolves nearly all of these. What must never happen is
    // the throw reaching the dispatcher: on the Logs page, of all places, an
    // error dialog about failing to copy the error log is absurd.
    // -----------------------------------------------------------------------

    private const int ClipboardAttempts = 10;
    private const int ClipboardRetryMilliseconds = 100;

    private void OnCopyClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is null) return;

        // Already redacted by the LogBus, so this is safe to put on the clipboard.
        string text = ViewModel.CopyText();

        for (int attempt = 1; attempt <= ClipboardAttempts; attempt++)
        {
            try
            {
                // SetDataObject with copy:true rather than SetText: it is the
                // call that leaves the data on the clipboard after this process
                // exits, which is what someone pasting into a bug report needs.
                Clipboard.SetDataObject(text, copy: true);
                ViewModel.CopyStatus = $"copied {text.Length:N0} characters";
                return;
            }
            catch (Exception ex) when (attempt < ClipboardAttempts && IsTransientClipboardFailure(ex))
            {
                Thread.Sleep(ClipboardRetryMilliseconds);
            }
            catch (Exception ex)
            {
                ViewModel.CopyStatus =
                    "could not copy: another program is holding the clipboard. "
                    + "Use Save to file instead.";
                ((App)Application.Current).Services.LogBus
                    .Warning("logs", $"clipboard copy failed after {attempt} attempt(s): {ex.Message}");
                return;
            }
        }
    }

    /// <summary>
    /// True for the "someone else has the clipboard open" failures, which are
    /// worth retrying. Anything else is not, and retrying would only delay the
    /// message.
    /// </summary>
    private static bool IsTransientClipboardFailure(Exception ex) =>
        ex is System.Runtime.InteropServices.COMException { HResult: unchecked((int)0x800401D0) }
        or System.Runtime.InteropServices.ExternalException;

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is null) return;

        var dialog = new SaveFileDialog
        {
            FileName = $"runnerforge-{DateTime.Now:yyyyMMdd-HHmmss}.log",
            Filter = "Log files (*.log)|*.log|All files (*.*)|*.*",
        };

        if (dialog.ShowDialog() != true) return;

        // Saving can fail too — a read-only folder, OneDrive mid-sync — and the
        // same reasoning applies: report it here, never as a crash dialog.
        try
        {
            ViewModel.SaveTo(dialog.FileName);
            ViewModel.CopyStatus = $"saved to {dialog.FileName}";
        }
        catch (Exception ex)
        {
            ViewModel.CopyStatus = $"could not save: {ex.Message}";
            ((App)Application.Current).Services.LogBus
                .Warning("logs", $"saving the log to {dialog.FileName} failed: {ex.Message}");
        }
    }
}
