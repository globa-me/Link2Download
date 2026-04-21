using System.IO;
using System.Windows;
using Link2Download.Windows.App.Services;
using Link2Download.Windows.App.ViewModels;
using Link2Download.Windows.Core.Services;
using Link2Download.Windows.Infrastructure.Diagnostics;
using Link2Download.Windows.Infrastructure.Persistence;
using Link2Download.Windows.Infrastructure.Runtime;

namespace Link2Download.Windows.App;

public partial class App : System.Windows.Application
{
    private MainViewModel? _viewModel;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var roamingRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Link2Download");
        var localRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Link2Download");

        var settingsRepository = new JsonSettingsRepository(Path.Combine(roamingRoot, "settings.json"));
        var historyRepository = new JsonHistoryRepository(Path.Combine(roamingRoot, "history.json"));
        var diagnostics = new FileDiagnosticsLogger(Path.Combine(localRoot, "logs", "app.log"));

        try
        {
            await EmbeddedRuntimeBootstrapper.PrepareAsync(localRoot, typeof(App).Assembly, diagnostics);
        }
        catch (Exception ex)
        {
            diagnostics.Warning($"Failed to prepare embedded runtime: {ex.Message}");
        }

        var runtimeService = new YtDlpDownloadRuntimeService(diagnostics);
        var dispatcher = new WpfUiDispatcher(Dispatcher);
        var downloadManager = new DownloadManager(runtimeService, historyRepository, diagnostics, dispatcher);

        _viewModel = new MainViewModel(downloadManager, settingsRepository, diagnostics);
        var window = new MainWindow(_viewModel);
        MainWindow = window;
        window.Show();

        try
        {
            await _viewModel.InitializeAsync();
        }
        catch (Exception ex)
        {
            diagnostics.Error($"App startup failed: {ex}");
            _viewModel.StatusMessage = $"Startup error: {ex.Message}";
        }
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        if (_viewModel is not null)
        {
            await _viewModel.DisposeAsync();
        }

        base.OnExit(e);
    }
}
