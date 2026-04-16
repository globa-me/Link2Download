using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Data;
using Link2Download.Windows.App.Commands;
using Link2Download.Windows.Core.Abstractions;
using Link2Download.Windows.Core.Models;
using Link2Download.Windows.Core.Services;
using Forms = System.Windows.Forms;

namespace Link2Download.Windows.App.ViewModels;

public sealed class MainViewModel : ObservableObject, IAsyncDisposable
{
    private readonly DownloadManager _downloadManager;
    private readonly ISettingsRepository _settingsRepository;
    private readonly IDiagnosticsLogger _diagnostics;
    private CancellationTokenSource? _settingsSaveCts;
    private string _inputUrl = string.Empty;
    private string _searchQuery = string.Empty;
    private ListFilter _selectedFilter = ListFilter.All;
    private string _statusMessage = "Place yt-dlp.exe and ffmpeg.exe into windows/runtime/win-x64/, then paste a link.";

    public MainViewModel(
        DownloadManager downloadManager,
        ISettingsRepository settingsRepository,
        IDiagnosticsLogger diagnostics)
    {
        _downloadManager = downloadManager;
        _settingsRepository = settingsRepository;
        _diagnostics = diagnostics;
        Settings = DownloadPreferences.CreateDefault();
        Settings.PropertyChanged += SettingsOnPropertyChanged;

        DownloadsView = CollectionViewSource.GetDefaultView(_downloadManager.Records);
        DownloadsView.Filter = FilterDownload;
        DownloadsView.SortDescriptions.Add(new SortDescription(nameof(DownloadRecord.UpdatedAt), ListSortDirection.Descending));

        _downloadManager.Changed += (_, _) => System.Windows.Application.Current.Dispatcher.Invoke(UpdateComputedState);

        StartDownloadCommand = new AsyncRelayCommand(_ => StartDownloadAsync());
        PasteAndQueueCommand = new AsyncRelayCommand(_ => PasteAndQueueAsync());
        BrowseSaveFolderCommand = new RelayCommand(_ => BrowseSaveFolder());
        ResetDefaultsCommand = new RelayCommand(_ => ResetDefaults());
        OpenFileCommand = new RelayCommand(parameter => OpenFile(parameter as DownloadRecord));
        ShowInExplorerCommand = new RelayCommand(parameter => ShowInExplorer(parameter as DownloadRecord));
        CopySourceUrlCommand = new RelayCommand(parameter => CopySourceUrl(parameter as DownloadRecord));
        OpenSourceUrlCommand = new RelayCommand(parameter => OpenSourceUrl(parameter as DownloadRecord));
        RetryCommand = new AsyncRelayCommand(parameter => RetryAsync(parameter as DownloadRecord));
        CancelCommand = new AsyncRelayCommand(parameter => CancelAsync(parameter as DownloadRecord));
        RemoveCommand = new AsyncRelayCommand(parameter => RemoveAsync(parameter as DownloadRecord));

        Languages =
        [
            new EnumOption<AppLanguage>(AppLanguage.System, "System"),
            new EnumOption<AppLanguage>(AppLanguage.English, "English"),
            new EnumOption<AppLanguage>(AppLanguage.Russian, "Russian"),
            new EnumOption<AppLanguage>(AppLanguage.Hindi, "Hindi"),
            new EnumOption<AppLanguage>(AppLanguage.Chinese, "Chinese")
        ];

        Filters =
        [
            new EnumOption<ListFilter>(ListFilter.All, "All"),
            new EnumOption<ListFilter>(ListFilter.Video, "Video"),
            new EnumOption<ListFilter>(ListFilter.Audio, "Audio")
        ];

        DownloadKinds =
        [
            new EnumOption<DownloadKind>(DownloadKind.Video, "Video"),
            new EnumOption<DownloadKind>(DownloadKind.Audio, "Audio")
        ];

        QualityPresets =
        [
            new EnumOption<QualityPreset>(QualityPreset.Best, "Best"),
            new EnumOption<QualityPreset>(QualityPreset.P720, "720p"),
            new EnumOption<QualityPreset>(QualityPreset.P1080, "1080p"),
            new EnumOption<QualityPreset>(QualityPreset.P4K, "4K"),
            new EnumOption<QualityPreset>(QualityPreset.P8K, "8K")
        ];

        VideoFormats =
        [
            new EnumOption<VideoFormat>(VideoFormat.Mp4, "MP4"),
            new EnumOption<VideoFormat>(VideoFormat.Mkv, "MKV")
        ];

        AudioFormats =
        [
            new EnumOption<AudioFormat>(AudioFormat.Mp3, "MP3"),
            new EnumOption<AudioFormat>(AudioFormat.M4a, "M4A"),
            new EnumOption<AudioFormat>(AudioFormat.Ogg, "OGG")
        ];

        SpeedLimits =
        [
            new EnumOption<SpeedLimitPreset>(SpeedLimitPreset.Unlimited, "Unlimited"),
            new EnumOption<SpeedLimitPreset>(SpeedLimitPreset.Mbps50, "50 Mbps"),
            new EnumOption<SpeedLimitPreset>(SpeedLimitPreset.Mbps25, "25 Mbps"),
            new EnumOption<SpeedLimitPreset>(SpeedLimitPreset.Mbps10, "10 Mbps"),
            new EnumOption<SpeedLimitPreset>(SpeedLimitPreset.Mbps4, "4 Mbps")
        ];

        CookieSources =
        [
            new EnumOption<BrowserCookieSource>(BrowserCookieSource.Auto, "Auto"),
            new EnumOption<BrowserCookieSource>(BrowserCookieSource.None, "Disabled"),
            new EnumOption<BrowserCookieSource>(BrowserCookieSource.Edge, "Edge"),
            new EnumOption<BrowserCookieSource>(BrowserCookieSource.Chrome, "Chrome"),
            new EnumOption<BrowserCookieSource>(BrowserCookieSource.Firefox, "Firefox"),
            new EnumOption<BrowserCookieSource>(BrowserCookieSource.Chromium, "Chromium")
        ];
    }

    public DownloadPreferences Settings { get; }

    public ICollectionView DownloadsView { get; }

    public IReadOnlyList<EnumOption<AppLanguage>> Languages { get; }

    public IReadOnlyList<EnumOption<ListFilter>> Filters { get; }

    public IReadOnlyList<EnumOption<DownloadKind>> DownloadKinds { get; }

    public IReadOnlyList<EnumOption<QualityPreset>> QualityPresets { get; }

    public IReadOnlyList<EnumOption<VideoFormat>> VideoFormats { get; }

    public IReadOnlyList<EnumOption<AudioFormat>> AudioFormats { get; }

    public IReadOnlyList<EnumOption<SpeedLimitPreset>> SpeedLimits { get; }

    public IReadOnlyList<EnumOption<BrowserCookieSource>> CookieSources { get; }

    public AsyncRelayCommand StartDownloadCommand { get; }

    public AsyncRelayCommand PasteAndQueueCommand { get; }

    public RelayCommand BrowseSaveFolderCommand { get; }

    public RelayCommand ResetDefaultsCommand { get; }

    public RelayCommand OpenFileCommand { get; }

    public RelayCommand ShowInExplorerCommand { get; }

    public RelayCommand CopySourceUrlCommand { get; }

    public RelayCommand OpenSourceUrlCommand { get; }

    public AsyncRelayCommand RetryCommand { get; }

    public AsyncRelayCommand CancelCommand { get; }

    public AsyncRelayCommand RemoveCommand { get; }

    public string InputUrl
    {
        get => _inputUrl;
        set => SetProperty(ref _inputUrl, value);
    }

    public string SearchQuery
    {
        get => _searchQuery;
        set
        {
            if (SetProperty(ref _searchQuery, value))
            {
                DownloadsView.Refresh();
            }
        }
    }

    public ListFilter SelectedFilter
    {
        get => _selectedFilter;
        set
        {
            if (SetProperty(ref _selectedFilter, value))
            {
                DownloadsView.Refresh();
            }
        }
    }

    public string StatusMessage
    {
        get => _statusMessage;
        set => SetProperty(ref _statusMessage, value);
    }

    public int ActiveCount => _downloadManager.Records.Count(record => record.Status == DownloadStatus.Downloading);

    public int QueuedCount => _downloadManager.Records.Count(record => record.Status == DownloadStatus.Queued);

    public int CompletedCount => _downloadManager.Records.Count(record => record.Status == DownloadStatus.Completed);

    public int FailedCount => _downloadManager.Records.Count(record => record.Status == DownloadStatus.Failed);

    public string LogFilePath => _diagnostics.LogFilePath;

    public async Task InitializeAsync()
    {
        var loaded = await _settingsRepository.LoadAsync();
        if (loaded is not null)
        {
            Settings.ApplyFrom(loaded);
        }

        Settings.EnsureSaveDirectoryExists();
        await _downloadManager.InitializeAsync();
        UpdateComputedState();
        StatusMessage = "Windows queue is ready. Paste a link and start the first download.";
    }

    public async ValueTask DisposeAsync()
    {
        _settingsSaveCts?.Cancel();
        _settingsSaveCts?.Dispose();
        Settings.PropertyChanged -= SettingsOnPropertyChanged;
        await _settingsRepository.SaveAsync(Settings.Clone());
        await _downloadManager.FlushAsync();
    }

    private async Task StartDownloadAsync()
    {
        try
        {
            await _downloadManager.EnqueueAsync(InputUrl, Settings.Clone());
            StatusMessage = "Download queued.";
            InputUrl = string.Empty;
        }
        catch (Exception ex)
        {
            StatusMessage = ex.Message;
            _diagnostics.Warning($"Failed to enqueue URL: {ex.Message}");
        }
    }

    private async Task PasteAndQueueAsync()
    {
        try
        {
            if (System.Windows.Clipboard.ContainsText())
            {
                InputUrl = System.Windows.Clipboard.GetText().Trim();
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Clipboard is unavailable: {ex.Message}";
            return;
        }

        await StartDownloadAsync();
    }

    private void BrowseSaveFolder()
    {
        using var dialog = new Forms.FolderBrowserDialog
        {
            SelectedPath = Directory.Exists(Settings.SaveDirectory)
                ? Settings.SaveDirectory
                : DownloadPreferences.GetDefaultSaveDirectory(),
            ShowNewFolderButton = true
        };

        if (dialog.ShowDialog() == Forms.DialogResult.OK)
        {
            Settings.SaveDirectory = dialog.SelectedPath;
            Settings.EnsureSaveDirectoryExists();
            StatusMessage = $"Saving downloads to {Settings.SaveDirectory}";
        }
    }

    private void ResetDefaults()
    {
        Settings.ApplyFrom(DownloadPreferences.CreateDefault());
        StatusMessage = "Settings were reset to defaults.";
    }

    private void OpenFile(DownloadRecord? record)
    {
        if (record is null || string.IsNullOrWhiteSpace(record.FilePath) || !File.Exists(record.FilePath))
        {
            StatusMessage = "The downloaded file is not available on disk.";
            return;
        }

        Process.Start(new ProcessStartInfo(record.FilePath!) { UseShellExecute = true });
    }

    private void ShowInExplorer(DownloadRecord? record)
    {
        if (record is null || string.IsNullOrWhiteSpace(record.FilePath) || !File.Exists(record.FilePath))
        {
            StatusMessage = "The downloaded file is not available on disk.";
            return;
        }

        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{record.FilePath}\"") { UseShellExecute = true });
    }

    private void CopySourceUrl(DownloadRecord? record)
    {
        if (record is null || string.IsNullOrWhiteSpace(record.SourceUrl))
        {
            return;
        }

        System.Windows.Clipboard.SetText(record.SourceUrl);
        StatusMessage = "Source URL copied to clipboard.";
    }

    private void OpenSourceUrl(DownloadRecord? record)
    {
        if (record is null || string.IsNullOrWhiteSpace(record.SourceUrl))
        {
            return;
        }

        Process.Start(new ProcessStartInfo(record.SourceUrl) { UseShellExecute = true });
    }

    private async Task RetryAsync(DownloadRecord? record)
    {
        if (record is null)
        {
            return;
        }

        try
        {
            await _downloadManager.RetryAsync(record.Id, Settings.Clone());
            StatusMessage = "Retry queued.";
        }
        catch (Exception ex)
        {
            StatusMessage = ex.Message;
        }
    }

    private async Task CancelAsync(DownloadRecord? record)
    {
        if (record is null)
        {
            return;
        }

        await _downloadManager.CancelAsync(record.Id);
        StatusMessage = "Cancellation requested.";
    }

    private async Task RemoveAsync(DownloadRecord? record)
    {
        if (record is null)
        {
            return;
        }

        await _downloadManager.RemoveAsync(record.Id);
        StatusMessage = "Download removed from the list.";
    }

    private bool FilterDownload(object item)
    {
        if (item is not DownloadRecord record)
        {
            return false;
        }

        if (SelectedFilter == ListFilter.Video && record.Kind != DownloadKind.Video)
        {
            return false;
        }

        if (SelectedFilter == ListFilter.Audio && record.Kind != DownloadKind.Audio)
        {
            return false;
        }

        return record.MatchesQuery(SearchQuery);
    }

    private void SettingsOnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        ScheduleSettingsSave();
    }

    private void ScheduleSettingsSave()
    {
        var previous = _settingsSaveCts;
        _settingsSaveCts = new CancellationTokenSource();
        previous?.Cancel();
        previous?.Dispose();

        var token = _settingsSaveCts.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(300, token);
                await _settingsRepository.SaveAsync(Settings.Clone(), token);
            }
            catch (OperationCanceledException)
            {
            }
        }, token);
    }

    private void UpdateComputedState()
    {
        DownloadsView.Refresh();
        RaisePropertyChanged(nameof(ActiveCount));
        RaisePropertyChanged(nameof(QueuedCount));
        RaisePropertyChanged(nameof(CompletedCount));
        RaisePropertyChanged(nameof(FailedCount));
    }
}
