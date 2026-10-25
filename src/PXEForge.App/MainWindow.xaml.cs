using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using PXEForge.App.ViewModels;

namespace PXEForge.App;

public partial class MainWindow : Window
{
    private readonly MainViewModel _vm = new();
    private readonly DispatcherTimer _timer = new();
    private string _uiLogPath = string.Empty;

    // Lembra a última pasta usada para os dois diálogos.
    private static string _lastFolder = Environment.GetFolderPath(Environment.SpecialFolder.MyComputer);

    public MainWindow()
    {
        InitializeComponent();
        DataContext = _vm;

        try
        {
            _uiLogPath = Path.Combine(PXEForge.Core.Configuration.PxeConfig.AppDirectory, "pxeforge-ui-debug.txt");
            File.AppendAllText(_uiLogPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] UI started{Environment.NewLine}", Encoding.UTF8);
        }
        catch { }

        _timer.Interval = TimeSpan.FromSeconds(2);
        _timer.Tick += (_, _) => _vm.Refresh();
        _timer.Start();

        Loaded += (_, _) =>
        {
            _vm.Logs.Clear();
            _vm.SelectedSource = string.Empty;
            _vm.SourceType = "NENHUM";
            _vm.ProgressText = "Escolha a origem: CARREGAR .ISO (arquivo) ou SELECIONAR DIRETÓRIO (mídia já extraída).";
        };
    }

    private void LoadIso_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Title = "CARREGAR .ISO - selecione a imagem do Windows 10/11",
            Filter = "Imagem ISO (*.iso)|*.iso|Todos os arquivos (*.*)|*.*",
            FilterIndex = 1,
            CheckFileExists = true,
            Multiselect = false,
            InitialDirectory = ResolveInitialFolder()
        };

        if (dlg.ShowDialog(this) != true)
        {
            return;
        }

        _lastFolder = Path.GetDirectoryName(dlg.FileName) ?? _lastFolder;
        _vm.SelectedSource = dlg.FileName.Trim();
        _vm.SourceType = "ISO";
        _vm.ProgressText = $"ISO selecionada: {Path.GetFileName(dlg.FileName)}. Clique em Preparar mídia.";
    }

    private void SelectDir_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog
        {
            Title = "SELECIONAR DIRETÓRIO - aponte para a raiz da mídia já extraída",
            Multiselect = false,
            InitialDirectory = ResolveInitialFolder()
        };

        if (dlg.ShowDialog(this) != true)
        {
            return;
        }

        _lastFolder = dlg.FolderName;
        _vm.SelectedSource = dlg.FolderName.Trim();
        _vm.SourceType = "DIRETÓRIO";
        _vm.ProgressText = $"Diretório selecionado: {dlg.FolderName}. Clique em Preparar mídia.";
    }

    private static string ResolveInitialFolder()
    {
        try
        {
            if (!string.IsNullOrWhiteSpace(_lastFolder) && Directory.Exists(_lastFolder))
            {
                return _lastFolder;
            }
        }
        catch
        {
            // Ignore invalid stored path.
        }

        // Procura ISOs ao lado do executável e na pasta pai (evita "não aparece nada").
        foreach (var candidate in new[] { PXEForge.Core.Configuration.PxeConfig.AppDirectory, Directory.GetParent(PXEForge.Core.Configuration.PxeConfig.AppDirectory.TrimEnd('\\'))?.FullName })
        {
            try
            {
                if (candidate is not null && Directory.Exists(candidate) &&
                    Directory.EnumerateFiles(candidate, "*.iso").Any())
                {
                    return candidate;
                }
            }
            catch
            {
                // Ignore inaccessible folders.
            }
        }

        return PXEForge.Core.Configuration.PxeConfig.AppDirectory;
    }

    private async void Prepare_Click(object sender, RoutedEventArgs e)
    {
        await _vm.PrepareAsync();
    }

    private async void Start_Click(object sender, RoutedEventArgs e)
    {
        await _vm.StartAsync();
    }

    private async void Stop_Click(object sender, RoutedEventArgs e)
    {
        await _vm.StopAsync();
    }

    private async void Test_Click(object sender, RoutedEventArgs e)
    {
        await _vm.RunTestsAsync();
    }
}
