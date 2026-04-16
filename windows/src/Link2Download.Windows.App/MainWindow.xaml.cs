using System.Windows;
using Link2Download.Windows.App.ViewModels;

namespace Link2Download.Windows.App;

public partial class MainWindow : Window
{
    public MainWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        DataContext = viewModel;
    }
}
