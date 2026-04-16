namespace Link2Download.Windows.Core.Abstractions;

public interface IUiDispatcher
{
    Task InvokeAsync(Action action);

    Task<T> InvokeAsync<T>(Func<T> action);
}
