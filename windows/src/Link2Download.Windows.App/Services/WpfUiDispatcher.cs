using System.Windows.Threading;
using Link2Download.Windows.Core.Abstractions;

namespace Link2Download.Windows.App.Services;

public sealed class WpfUiDispatcher : IUiDispatcher
{
    private readonly Dispatcher _dispatcher;

    public WpfUiDispatcher(Dispatcher dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public Task InvokeAsync(Action action)
    {
        return _dispatcher.InvokeAsync(action).Task;
    }

    public Task<T> InvokeAsync<T>(Func<T> action)
    {
        return _dispatcher.InvokeAsync(action).Task;
    }
}
