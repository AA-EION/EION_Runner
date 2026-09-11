using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;

namespace RunnerForge.ViewModels;

/// <summary>
/// Hand-rolled MVVM base. No third-party package: the whole surface a WPF app
/// needs from one is property-change notification and a command type, and both
/// fit in this file.
/// </summary>
public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));

    /// <summary>
    /// Raises PropertyChanged for a COMPUTED property whose inputs changed.
    /// Public because a computed property's dependency often lives outside the
    /// type that exposes it.
    /// </summary>
    public void OnPropertyChangedPublic(string propertyName) => OnPropertyChanged(propertyName);

    /// <summary>Assigns and notifies only when the value actually changed.</summary>
    protected bool SetProperty<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }
}

/// <summary>A command backed by a delegate.</summary>
public sealed class RelayCommand(Action<object?> execute, Func<object?, bool>? canExecute = null) : ICommand
{
    private readonly Action<object?> _execute = execute;
    private readonly Func<object?, bool>? _canExecute = canExecute;

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => _canExecute?.Invoke(parameter) ?? true;

    public void Execute(object? parameter) => _execute(parameter);

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

/// <summary>
/// An async command that disables itself while running, so a slow operation
/// cannot be started twice by an impatient double-click.
/// </summary>
public sealed class AsyncRelayCommand(
    Func<object?, Task> execute, Func<object?, bool>? canExecute = null) : ICommand
{
    private readonly Func<object?, Task> _execute = execute;
    private readonly Func<object?, bool>? _canExecute = canExecute;
    private bool _isRunning;

    public event EventHandler? CanExecuteChanged;

    public bool IsRunning
    {
        get => _isRunning;
        private set { _isRunning = value; RaiseCanExecuteChanged(); }
    }

    public bool CanExecute(object? parameter) => !_isRunning && (_canExecute?.Invoke(parameter) ?? true);

    public async void Execute(object? parameter)
    {
        if (!CanExecute(parameter)) return;

        IsRunning = true;
        try
        {
            await _execute(parameter).ConfigureAwait(true);
        }
        finally
        {
            IsRunning = false;
        }
    }

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
