#Requires -Version 5.1
# Freshservice KB Export v3.3: mode Analytics automatique + preferences chiffrées via SecureString

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:CurrentExportRoot = $null

# -----------------------------------------------------------------------------
# Interface graphique
# -----------------------------------------------------------------------------

function Show-InformationMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Title = 'Freshservice Knowledge Base Export'
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Show-WarningMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Title = 'Freshservice Knowledge Base Export'
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}

function Show-ErrorMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Title = "Erreur pendant l'export Freshservice"
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Normalize-FreshserviceDomain {
    param(
        [Parameter(Mandatory)]
        [string]$Domain
    )

    $Normalized = $Domain.Trim()
    $Normalized = $Normalized -replace '^https?://', ''
    $Normalized = $Normalized.TrimEnd('/')

    return $Normalized
}

# Parametres utilisateurs sans secret en clair.
# Les valeurs sensibles sont protegees par ConvertFrom-SecureString (DPAPI Windows CurrentUser).
function Get-FreshserviceSettingsPath {
    $Base = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Freshservice\KnowledgeBaseExport'
    if (-not (Test-Path -LiteralPath $Base -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $Base -Force)
    }
    return (Join-Path $Base 'settings.json')
}

function Protect-SettingString {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    # Windows PowerShell : ConvertFrom-SecureString sans -Key utilise DPAPI
    # avec le contexte du compte Windows courant, sans assembly .NET externe.
    $SecureValue = $null
    try {
        $SecureValue = ConvertTo-SecureString -String $Value -AsPlainText -Force -ErrorAction Stop
        $EncryptedValue = ConvertFrom-SecureString -SecureString $SecureValue -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($EncryptedValue)) {
            throw 'La protection Windows a retourne une valeur vide.'
        }
        return ('PSDPAPI:' + $EncryptedValue)
    }
    finally {
        if ($null -ne $SecureValue) { $SecureValue.Dispose() }
    }
}

function Unprotect-SettingString {
    param([string]$EncryptedValue)
    if ([string]::IsNullOrWhiteSpace($EncryptedValue)) { return '' }

    # Seul le format cree par cette version est relu. Les anciennes tentatives
    # ayant echoue ne sont pas interpretees comme des secrets valides.
    if (-not $EncryptedValue.StartsWith('PSDPAPI:', [StringComparison]::Ordinal)) {
        return ''
    }

    $SecureValue = $null
    $Bstr = [IntPtr]::Zero
    try {
        $CipherText = $EncryptedValue.Substring('PSDPAPI:'.Length)
        $SecureValue = ConvertTo-SecureString -String $CipherText -ErrorAction Stop
        $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
    }
    catch {
        return '' # Autre profil Windows, valeur endommagee ou indisponible.
    }
    finally {
        if ($Bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
        }
        if ($null -ne $SecureValue) { $SecureValue.Dispose() }
    }
}

function Read-FreshserviceSettings {
    # La lecture ne doit jamais tenter de creer un dossier : utile sur les postes geres.
    $Base = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($Base)) { return $null }
    $Path = Join-Path $Base 'Freshservice\KnowledgeBaseExport\settings.json'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $Path -Encoding UTF8 -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Save-FreshserviceSettings {
    param([Parameter(Mandatory)]$Configuration)
    $SaveUrl = ''
    $SaveApiKey = ''
    $Warnings = New-Object 'System.Collections.Generic.List[string]'
    if ($Configuration.RememberConfiguration) {
        if (-not [string]::IsNullOrWhiteSpace($Configuration.AutomaticUrl)) {
            try { $SaveUrl = Protect-SettingString -Value $Configuration.AutomaticUrl }
            catch { $Warnings.Add('URL Analytics non memorisee : ' + $_.Exception.Message) }
        }
        if ($Configuration.RememberApiKey) {
            try { $SaveApiKey = Protect-SettingString -Value $Configuration.ApiKey }
            catch { $Warnings.Add('Cle API non memorisee : ' + $_.Exception.Message) }
        }
    }
    $Data = [ordered]@{
        Domain = [string]$Configuration.Domain
        ExportPath = [string]$Configuration.ExportPath
        SourceMode = [string]$Configuration.SourceMode
        OpenFolder = [bool]$Configuration.OpenFolder
        RememberConfiguration = [bool]$Configuration.RememberConfiguration
        RememberApiKey = [bool]($Configuration.RememberApiKey -and $SaveApiKey)
        AutomaticUrlEncrypted = $SaveUrl
        ApiKeyEncrypted = $SaveApiKey
    }
    $Path = Get-FreshserviceSettingsPath
    $Data | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
    # Les preferences ordinaires restent enregistrees meme si DPAPI est indisponible.
    return $Warnings.ToArray()
}

function Clear-FreshserviceSettings {
    # En desactivant la memorisation, supprimer aussi une ancienne sauvegarde.
    $Base = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($Base)) { return }
    $Path = Join-Path $Base 'Freshservice\KnowledgeBaseExport\settings.json'
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
}

function Test-AutomaticExportUrl {
    param([string]$Url, [string]$ExpectedDomain)
    $UriObject = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$UriObject)) { return $false }
    if ($UriObject.Scheme -ne 'https' -or -not [string]::IsNullOrWhiteSpace($UriObject.UserInfo)) { return $false }
    # Ne pas transmettre la cle API a une URL hors du tenant configure.
    return ($UriObject.Host -ieq $ExpectedDomain)
}

# Fenetre moderne de selection de dossiers (Explorateur Windows).
# Windows PowerShell 5.1 utilise par defaut l'ancien FolderBrowserDialog.
# IFileDialog + FOS_PICKFOLDERS ouvre le selecteur moderne Windows 10/11.
function Select-ModernExportFolder {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$InitialFolder = '',
        [System.Windows.Forms.IWin32Window]$Owner = $null
    )
    if (-not ('FreshserviceFolderPicker.NativeFolderDialog' -as [type])) {
        $Source = @'
using System;
using System.Runtime.InteropServices;

namespace FreshserviceFolderPicker {
    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    internal class FileOpenDialogClass { }

    [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileDialog {
        [PreserveSig] int Show(IntPtr hwndOwner);
        void SetFileTypes(uint count, IntPtr filters);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem folder);
        void SetFolder(IShellItem folder);
        void GetFolder(out IShellItem folder);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string filename);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string filename);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetResult(out IShellItem item);
        void AddPlace(IShellItem item, uint fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr filter);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem {
        void BindToHandler(IntPtr bindContext, ref Guid handler, ref Guid riid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint sigdn, out IntPtr name);
        void GetAttributes(uint mask, out uint flags);
        void Compare(IShellItem item, uint hint, out int order);
    }

    public static class NativeFolderDialog {
        [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
        private static extern void SHCreateItemFromParsingName(
            [MarshalAs(UnmanagedType.LPWStr)] string path,
            IntPtr bindContext,
            ref Guid riid,
            out IShellItem item);

        public static string SelectFolder(string title, string initialFolder, IntPtr owner) {
            IFileDialog dialog = null;
            IShellItem initialItem = null;
            IShellItem selectedItem = null;
            IntPtr namePtr = IntPtr.Zero;
            try {
                dialog = (IFileDialog)new FileOpenDialogClass();
                uint options;
                dialog.GetOptions(out options);
                // FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST
                dialog.SetOptions(options | 0x00000020 | 0x00000040 | 0x00000800);
                dialog.SetTitle(title);
                dialog.SetOkButtonLabel("Selectionner ce dossier");
                if (!String.IsNullOrEmpty(initialFolder) &&
                    System.IO.Directory.Exists(initialFolder)) {
                    try {
                        Guid riid = typeof(IShellItem).GUID;
                        SHCreateItemFromParsingName(initialFolder, IntPtr.Zero, ref riid, out initialItem);
                        if (initialItem != null) dialog.SetFolder(initialItem);
                    } catch (COMException) { /* Le navigateur choisira son dossier initial. */ }
                }
                int result = dialog.Show(owner);
                // HRESULT_FROM_WIN32(ERROR_CANCELLED)
                if (result == unchecked((int)0x800704C7)) return null;
                if (result != 0) Marshal.ThrowExceptionForHR(result);
                dialog.GetResult(out selectedItem);
                // SIGDN_FILESYSPATH
                selectedItem.GetDisplayName(0x80058000, out namePtr);
                return Marshal.PtrToStringUni(namePtr);
            }
            finally {
                if (namePtr != IntPtr.Zero) Marshal.FreeCoTaskMem(namePtr);
                if (selectedItem != null) Marshal.ReleaseComObject(selectedItem);
                if (initialItem != null && !Object.ReferenceEquals(initialItem, selectedItem)) Marshal.ReleaseComObject(initialItem);
                if (dialog != null) Marshal.ReleaseComObject(dialog);
            }
        }
    }
}
'@
        Add-Type -TypeDefinition $Source -ReferencedAssemblies @('System.dll') -ErrorAction Stop
    }
    $Handle = if ($null -ne $Owner) { $Owner.Handle } else { [IntPtr]::Zero }
    return [FreshserviceFolderPicker.NativeFolderDialog]::SelectFolder($Title, $InitialFolder, $Handle)
}

function Get-ExportConfiguration {
    $Settings = Read-FreshserviceSettings
    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = 'Freshservice - Knowledge Base Export v3.3'
    $Form.Size = New-Object System.Drawing.Size(790, 680)
    $Form.StartPosition = 'CenterScreen'
    $Form.FormBorderStyle = 'FixedDialog'
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.ShowIcon = $false
    $Form.TopMost = $true

    $Title = New-Object System.Windows.Forms.Label
    $Title.Text = 'Export de la Knowledge Base Freshservice'
    $Title.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $Title.Location = New-Object System.Drawing.Point(22, 18)
    $Title.Size = New-Object System.Drawing.Size(730, 30)
    $Form.Controls.Add($Title)

    $Intro = New-Object System.Windows.Forms.Label
    $Intro.Text = "Export des articles par API. Choisir le fichier de reporting ou configurer un export Analytics planifie."
    $Intro.Location = New-Object System.Drawing.Point(24, 57)
    $Intro.Size = New-Object System.Drawing.Size(710, 32)
    $Form.Controls.Add($Intro)

    $DomainLabel = New-Object System.Windows.Forms.Label
    $DomainLabel.Text = 'Domaine Freshservice :'
    $DomainLabel.Location = New-Object System.Drawing.Point(24, 103)
    $DomainLabel.Size = New-Object System.Drawing.Size(205, 24)
    $Form.Controls.Add($DomainLabel)

    $DomainTextBox = New-Object System.Windows.Forms.TextBox
    $DomainTextBox.Location = New-Object System.Drawing.Point(235, 100)
    $DomainTextBox.Size = New-Object System.Drawing.Size(500, 26)
    $DomainTextBox.Text = 'yourcompany.freshservice.com'
    if ($null -ne $Settings -and $Settings.Domain) { $DomainTextBox.Text = [string]$Settings.Domain }
    $Form.Controls.Add($DomainTextBox)

    $ApiKeyLabel = New-Object System.Windows.Forms.Label
    $ApiKeyLabel.Text = 'Cle API Freshservice :'
    $ApiKeyLabel.Location = New-Object System.Drawing.Point(24, 144)
    $ApiKeyLabel.Size = New-Object System.Drawing.Size(205, 24)
    $Form.Controls.Add($ApiKeyLabel)

    $ApiKeyTextBox = New-Object System.Windows.Forms.TextBox
    $ApiKeyTextBox.Location = New-Object System.Drawing.Point(235, 141)
    $ApiKeyTextBox.Size = New-Object System.Drawing.Size(500, 26)
    $ApiKeyTextBox.UseSystemPasswordChar = $true
    if ($null -ne $Settings -and $Settings.ApiKeyEncrypted) {
        $ApiKeyTextBox.Text = Unprotect-SettingString -EncryptedValue ([string]$Settings.ApiKeyEncrypted)
    }
    $Form.Controls.Add($ApiKeyTextBox)

    $PasswordLabel = New-Object System.Windows.Forms.Label
    $PasswordLabel.Text = 'Basic Auth (valeur fictive) :'
    $PasswordLabel.Location = New-Object System.Drawing.Point(24, 185)
    $PasswordLabel.Size = New-Object System.Drawing.Size(205, 24)
    $Form.Controls.Add($PasswordLabel)
    $PasswordTextBox = New-Object System.Windows.Forms.TextBox
    $PasswordTextBox.Location = New-Object System.Drawing.Point(235, 182)
    $PasswordTextBox.Size = New-Object System.Drawing.Size(500, 26)
    $PasswordTextBox.Text = 'X'
    $PasswordTextBox.ReadOnly = $true
    $Form.Controls.Add($PasswordTextBox)

    $AutoRadio = New-Object System.Windows.Forms.RadioButton
    $AutoRadio.Text = 'Automatique - inventaire Analytics (recommande)'
    $AutoRadio.Location = New-Object System.Drawing.Point(235, 225)
    $AutoRadio.Size = New-Object System.Drawing.Size(500, 26)
    $Form.Controls.Add($AutoRadio)

    $ManualRadio = New-Object System.Windows.Forms.RadioButton
    $ManualRadio.Text = 'Manuel - choisir un fichier CSV ou XLSX'
    $ManualRadio.Location = New-Object System.Drawing.Point(235, 252)
    $ManualRadio.Size = New-Object System.Drawing.Size(500, 26)
    $Form.Controls.Add($ManualRadio)

    # Le mode automatique est restaure uniquement si l'URL sauvegardee est decryptable.
    # La configuration automatique ne doit jamais etre activee par defaut
    # sans URL d'export precedemment enregistree et decryptable.
    $SavedAutomaticUrl = ''
    if ($null -ne $Settings -and $Settings.AutomaticUrlEncrypted) {
        $SavedAutomaticUrl = Unprotect-SettingString -EncryptedValue ([string]$Settings.AutomaticUrlEncrypted)
    }
    if ($null -ne $Settings -and [string]$Settings.SourceMode -eq 'Automatic' -and
        -not [string]::IsNullOrWhiteSpace($SavedAutomaticUrl)) {
        $AutoRadio.Checked = $true
    }
    else { $ManualRadio.Checked = $true }

    $UrlLabel = New-Object System.Windows.Forms.Label
    $UrlLabel.Text = "URL d'export Analytics :"
    $UrlLabel.Location = New-Object System.Drawing.Point(24, 301)
    $UrlLabel.Size = New-Object System.Drawing.Size(205, 24)
    $Form.Controls.Add($UrlLabel)
    $UrlTextBox = New-Object System.Windows.Forms.TextBox
    $UrlTextBox.Location = New-Object System.Drawing.Point(235, 298)
    $UrlTextBox.Size = New-Object System.Drawing.Size(500, 26)
    if ($null -ne $Settings -and $Settings.AutomaticUrlEncrypted) {
        $UrlTextBox.Text = $SavedAutomaticUrl
    }
    $Form.Controls.Add($UrlTextBox)

    $Info = New-Object System.Windows.Forms.Label
    $Info.Text = 'URL du Data Export Solutions programme : Analytics > Settings > Data Export. La liste des ID est recuperee automatiquement.'
    $Info.Location = New-Object System.Drawing.Point(235, 327)
    $Info.Size = New-Object System.Drawing.Size(510, 40)
    $Info.ForeColor = [System.Drawing.Color]::DimGray
    $Form.Controls.Add($Info)

    $SourceFileLabel = New-Object System.Windows.Forms.Label
    $SourceFileLabel.Text = 'Reporting CSV ou XLSX :'
    $SourceFileLabel.Location = New-Object System.Drawing.Point(24, 372)
    $SourceFileLabel.Size = New-Object System.Drawing.Size(205, 24)
    $Form.Controls.Add($SourceFileLabel)

    $SourceFileTextBox = New-Object System.Windows.Forms.TextBox
    $SourceFileTextBox.Location = New-Object System.Drawing.Point(235, 369)
    $SourceFileTextBox.Size = New-Object System.Drawing.Size(392, 26)
    $SourceFileTextBox.ReadOnly = $true
    $Form.Controls.Add($SourceFileTextBox)

    $BrowseSourceButton = New-Object System.Windows.Forms.Button
    $BrowseSourceButton.Text = 'Parcourir...'
    $BrowseSourceButton.Location = New-Object System.Drawing.Point(637, 367)
    $BrowseSourceButton.Size = New-Object System.Drawing.Size(98, 30)
    $Form.Controls.Add($BrowseSourceButton)
    $BrowseSourceButton.Add_Click({
        $FileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $FileDialog.Title = 'Selectionner le fichier reporting Freshservice (CSV ou XLSX)'
        $FileDialog.Filter = 'Fichiers CSV ou Excel (*.csv;*.xlsx)|*.csv;*.xlsx'
        $FileDialog.CheckFileExists = $true
        $FileDialog.AutoUpgradeEnabled = $true
        if ($FileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $SourceFileTextBox.Text = $FileDialog.FileName
        }
        $FileDialog.Dispose()
    })

    $ExportPathLabel = New-Object System.Windows.Forms.Label
    $ExportPathLabel.Text = "Dossier d'enregistrement :"
    $ExportPathLabel.Location = New-Object System.Drawing.Point(24, 421)
    $ExportPathLabel.Size = New-Object System.Drawing.Size(205, 24)
    $Form.Controls.Add($ExportPathLabel)

    $ExportPathTextBox = New-Object System.Windows.Forms.TextBox
    $ExportPathTextBox.Location = New-Object System.Drawing.Point(235, 418)
    $ExportPathTextBox.Size = New-Object System.Drawing.Size(392, 26)
    $ExportPathTextBox.ReadOnly = $true
    $DefaultExportPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
    if (-not (Test-Path -LiteralPath $DefaultExportPath -PathType Container)) {
        $DefaultExportPath = [Environment]::GetFolderPath('MyDocuments')
    }
    if ($null -ne $Settings -and $Settings.ExportPath -and
        (Test-Path -LiteralPath ([string]$Settings.ExportPath) -PathType Container)) {
        $DefaultExportPath = [string]$Settings.ExportPath
    }
    $ExportPathTextBox.Text = $DefaultExportPath
    $Form.Controls.Add($ExportPathTextBox)

    $BrowseExportButton = New-Object System.Windows.Forms.Button
    $BrowseExportButton.Text = 'Parcourir...'
    $BrowseExportButton.Location = New-Object System.Drawing.Point(637, 416)
    $BrowseExportButton.Size = New-Object System.Drawing.Size(98, 30)
    $Form.Controls.Add($BrowseExportButton)
    $BrowseExportButton.Add_Click({
        try {
            $SelectedFolder = Select-ModernExportFolder -Title 'Selectionner le dossier de destination Freshservice KB' `
                -InitialFolder $ExportPathTextBox.Text -Owner $Form
            if (-not [string]::IsNullOrWhiteSpace($SelectedFolder)) {
                $ExportPathTextBox.Text = $SelectedFolder
            }
        }
        catch {
            Show-WarningMessage -Title 'Selection du dossier indisponible' `
                -Message ("Impossible d'ouvrir le navigateur de dossiers Windows.`r`n" + $_.Exception.Message)
        }
    })

    $OpenFolderCheckBox = New-Object System.Windows.Forms.CheckBox
    $OpenFolderCheckBox.Text = "Ouvrir le dossier d'export a la fin"
    $OpenFolderCheckBox.Location = New-Object System.Drawing.Point(235, 460)
    $OpenFolderCheckBox.Size = New-Object System.Drawing.Size(340, 24)
    $OpenFolderCheckBox.Checked = $true
    if ($null -ne $Settings -and $null -ne $Settings.OpenFolder) {
        $OpenFolderCheckBox.Checked = [bool]$Settings.OpenFolder
    }
    $Form.Controls.Add($OpenFolderCheckBox)

    $RememberCheckBox = New-Object System.Windows.Forms.CheckBox
    $RememberCheckBox.Text = "Memoriser les preferences et l'URL optionnelle (protection Windows)"
    $RememberCheckBox.Location = New-Object System.Drawing.Point(235, 490)
    $RememberCheckBox.Size = New-Object System.Drawing.Size(500, 24)
    $RememberCheckBox.Checked = $true
    if ($null -ne $Settings -and $null -ne $Settings.RememberConfiguration) {
        $RememberCheckBox.Checked = [bool]$Settings.RememberConfiguration
    }
    $Form.Controls.Add($RememberCheckBox)

    $RememberKeyCheckBox = New-Object System.Windows.Forms.CheckBox
    $RememberKeyCheckBox.Text = 'Memoriser aussi la cle API sur ce poste (protection Windows)'
    $RememberKeyCheckBox.Location = New-Object System.Drawing.Point(235, 518)
    $RememberKeyCheckBox.Size = New-Object System.Drawing.Size(500, 24)
    $RememberKeyCheckBox.Checked = $false
    if ($null -ne $Settings -and $null -ne $Settings.RememberApiKey) {
        $RememberKeyCheckBox.Checked = [bool]$Settings.RememberApiKey
    }
    $Form.Controls.Add($RememberKeyCheckBox)

    # Seuls les champs correspondant au mode choisi sont affiches.
    # Le mode manuel ne demande donc jamais d'URL Analytics.
    $RefreshSourceControls = {
        $IsAuto = $AutoRadio.Checked
        $UrlLabel.Visible = $IsAuto
        $UrlTextBox.Visible = $IsAuto
        $SourceFileLabel.Visible = -not $IsAuto
        $SourceFileTextBox.Visible = -not $IsAuto
        $BrowseSourceButton.Visible = -not $IsAuto
        if ($IsAuto) {
            $Info.Text = "Option avancee : coller l'URL du Data Export Freshservice planifie (si les articles KB sont proposes dans le module)."
        }
        else {
            $Info.Text = "Mode operationnel valide : selectionner le reporting Knowledge Base au format CSV ou XLSX. Aucune URL Analytics necessaire."
        }
    }
    $AutoRadio.Add_CheckedChanged($RefreshSourceControls)
    $ManualRadio.Add_CheckedChanged($RefreshSourceControls)
    & $RefreshSourceControls

    $StartButton = New-Object System.Windows.Forms.Button
    $StartButton.Text = "Lancer l'export"
    $StartButton.Location = New-Object System.Drawing.Point(480, 570)
    $StartButton.Size = New-Object System.Drawing.Size(145, 36)
    $StartButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $Form.Controls.Add($StartButton)

    $CancelButton = New-Object System.Windows.Forms.Button
    $CancelButton.Text = 'Annuler'
    $CancelButton.Location = New-Object System.Drawing.Point(637, 570)
    $CancelButton.Size = New-Object System.Drawing.Size(98, 36)
    $CancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $Form.Controls.Add($CancelButton)
    $Form.AcceptButton = $StartButton
    $Form.CancelButton = $CancelButton
    $Form.Add_Shown({ $ApiKeyTextBox.Select() })

    while ($true) {
        $Form.DialogResult = [System.Windows.Forms.DialogResult]::None
        $Result = $Form.ShowDialog()
        if ($Result -ne [System.Windows.Forms.DialogResult]::OK) {
            $Form.Dispose()
            return $null
        }

        $DomainRaw = $DomainTextBox.Text.Trim()
        $ApiKey = $ApiKeyTextBox.Text.Trim()
        $BasicPassword = $PasswordTextBox.Text
        $SourceMode = if ($AutoRadio.Checked) { 'Automatic' } else { 'Manual' }
        $AutoUrl = $UrlTextBox.Text.Trim()
        $SourceFile = $SourceFileTextBox.Text.Trim()
        $ExportPath = $ExportPathTextBox.Text.Trim()

        $Missing = New-Object 'System.Collections.Generic.List[string]'
        if (-not $DomainRaw) { $Missing.Add('Domaine Freshservice') }
        if (-not $ApiKey) { $Missing.Add('Cle API Freshservice') }
        if (-not $BasicPassword) { $Missing.Add('Basic Auth') }
        if ($SourceMode -eq 'Automatic' -and -not $AutoUrl) { $Missing.Add("URL d'export Analytics (uniquement en mode automatique)") }
        if ($SourceMode -eq 'Manual' -and -not $SourceFile) { $Missing.Add('Fichier reporting CSV ou XLSX') }
        if (-not $ExportPath) { $Missing.Add("Dossier d'enregistrement") }

        if ($Missing.Count -gt 0) {
            $MissingText = ($Missing.ToArray() | ForEach-Object { '- ' + $_ }) -join "`r`n"
            Show-WarningMessage -Title 'Champs obligatoires manquants' -Message "Tous les champs obligatoires doivent etre renseignes.`r`n`r`n$MissingText"
            continue
        }

        $Domain = Normalize-FreshserviceDomain -Domain $DomainRaw
        if ($Domain -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
            Show-WarningMessage -Title 'Domaine incorrect' -Message 'Exemple de domaine attendu : yourcompany.freshservice.com'
            continue
        }
        if ($SourceMode -eq 'Automatic') {
            if (-not (Test-AutomaticExportUrl -Url $AutoUrl -ExpectedDomain $Domain)) {
                Show-WarningMessage -Title 'URL Analytics incorrecte' -Message "L'URL doit etre HTTPS et appartenir au domaine Freshservice configure.`r`nElle doit etre l'URL API de Data Exports, et non l'adresse de la page du reporting."
                continue
            }
        }
        else {
            if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
                Show-WarningMessage -Title 'Fichier introuvable' -Message "Fichier reporting inaccessible :`r`n$SourceFile"
                continue
            }
            if ([IO.Path]::GetExtension($SourceFile).ToLowerInvariant() -notin @('.csv','.xlsx')) {
                Show-WarningMessage -Title 'Format incorrect' -Message 'Un fichier CSV ou XLSX est requis.'
                continue
            }
        }
        if (-not (Test-Path -LiteralPath $ExportPath -PathType Container)) {
            Show-WarningMessage -Title 'Dossier incorrect' -Message "Dossier de destination introuvable :`r`n$ExportPath"
            continue
        }
        if ($ExportPath.Length -gt 120) {
            Show-WarningMessage -Title 'Chemin trop long' -Message 'Choisir un dossier de destination plus court, par exemple dans votre profil Windows.'
            continue
        }
        $Configuration = [PSCustomObject]@{
            Domain = $Domain
            ApiKey = $ApiKey
            BasicPassword = $BasicPassword
            SourceMode = $SourceMode
            AutomaticUrl = $AutoUrl
            SourceFile = $SourceFile
            ExportPath = $ExportPath
            OpenFolder = $OpenFolderCheckBox.Checked
            RememberConfiguration = $RememberCheckBox.Checked
            RememberApiKey = $RememberCheckBox.Checked -and $RememberKeyCheckBox.Checked
        }
        $Form.Dispose()
        return $Configuration
    }
}

function New-ProgressWindow {
    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = 'Export Freshservice en cours'
    $Form.Size = New-Object System.Drawing.Size(650, 185)
    $Form.StartPosition = 'CenterScreen'
    $Form.FormBorderStyle = 'FixedDialog'
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.ControlBox = $false
    $Form.ShowIcon = $false
    $Form.TopMost = $true

    $Label = New-Object System.Windows.Forms.Label
    $Label.Text = "Initialisation de l'export..."
    $Label.Location = New-Object System.Drawing.Point(22, 22)
    $Label.Size = New-Object System.Drawing.Size(595, 62)
    $Label.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $Form.Controls.Add($Label)

    $ProgressBar = New-Object System.Windows.Forms.ProgressBar
    $ProgressBar.Location = New-Object System.Drawing.Point(22, 98)
    $ProgressBar.Size = New-Object System.Drawing.Size(595, 24)
    $ProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $ProgressBar.MarqueeAnimationSpeed = 30
    $Form.Controls.Add($ProgressBar)

    $Form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    return [PSCustomObject]@{
        Form        = $Form
        Label       = $Label
        ProgressBar = $ProgressBar
    }
}

function Update-ProgressWindow {
    param(
        [Parameter(Mandatory)]
        $ProgressWindow,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($null -ne $ProgressWindow -and $null -ne $ProgressWindow.Form) {
        $ProgressWindow.Label.Text = $Message
        $ProgressWindow.Form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Close-ProgressWindow {
    param(
        $ProgressWindow
    )

    if ($null -ne $ProgressWindow -and $null -ne $ProgressWindow.Form) {
        $ProgressWindow.Form.Close()
        $ProgressWindow.Form.Dispose()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

# -----------------------------------------------------------------------------
# Fonctions API
# -----------------------------------------------------------------------------

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    if ($null -eq $Object) {
        return $null
    }

    $Property = $Object.PSObject.Properties[$PropertyName]

    if ($null -eq $Property) {
        return $null
    }

    return $Property.Value
}

function Get-HttpStatusCode {
    param(
        [Parameter(Mandatory)]
        $Exception
    )

    try {
        if ($null -ne $Exception.Response -and $null -ne $Exception.Response.StatusCode) {
            return [int]$Exception.Response.StatusCode
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-RetryAfterSeconds {
    param(
        [Parameter(Mandatory)]
        $Exception,

        [int]$DefaultSeconds = 10
    )

    try {
        if ($null -ne $Exception.Response -and $null -ne $Exception.Response.Headers) {
            $RetryHeader = $Exception.Response.Headers['Retry-After']

            if (-not [string]::IsNullOrWhiteSpace([string]$RetryHeader)) {
                $RetrySeconds = 0

                if ([int]::TryParse([string]$RetryHeader, [ref]$RetrySeconds)) {
                    return $RetrySeconds
                }
            }
        }
    }
    catch {
        return $DefaultSeconds
    }

    return $DefaultSeconds
}

function Invoke-FreshserviceGet {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $MaximumAttempts = 6
    $Attempt = 0

    while ($Attempt -lt $MaximumAttempts) {
        $Attempt++

        try {
            return Invoke-RestMethod `
                -Method Get `
                -Uri $Uri `
                -Headers $Headers `
                -ContentType 'application/json' `
                -TimeoutSec 120
        }
        catch {
            $StatusCode = Get-HttpStatusCode -Exception $_.Exception
            $RetryAfter = Get-RetryAfterSeconds -Exception $_.Exception -DefaultSeconds ([Math]::Min(60, 5 * $Attempt))

            $CanRetry = (
                $StatusCode -eq 429 -or
                $StatusCode -eq 500 -or
                $StatusCode -eq 502 -or
                $StatusCode -eq 503 -or
                $StatusCode -eq 504
            )

            if ($CanRetry -and $Attempt -lt $MaximumAttempts) {
                Start-Sleep -Seconds $RetryAfter
                continue
            }

            $StatusText = if ($null -eq $StatusCode) { 'inconnu' } else { [string]$StatusCode }
            throw "Erreur HTTP $StatusText lors de l'appel GET : $Uri`r`n$($_.Exception.Message)"
        }
    }

    throw "Nombre maximal de tentatives atteint pour : $Uri"
}

function Get-ResponseCollection {
    param(
        [Parameter(Mandatory)]
        $Response,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    if ($null -eq $Response) {
        return @()
    }

    $Property = $Response.PSObject.Properties[$PropertyName]

    if ($null -ne $Property) {
        return @($Property.Value)
    }

    if ($Response -is [System.Array]) {
        return @($Response)
    }

    return @($Response)
}

function Get-FreshservicePagedCollection {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUri,

        [Parameter(Mandatory)]
        [string]$CollectionProperty,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [int]$PerPage = 100,

        $ProgressWindow
    )

    $Results = New-Object 'System.Collections.Generic.List[object]'
    $Page = 1

    while ($true) {
        $Separator = if ($BaseUri.Contains('?')) { '&' } else { '?' }
        $Uri = "$BaseUri${Separator}page=$Page&per_page=$PerPage"

        Update-ProgressWindow -ProgressWindow $ProgressWindow -Message "Lecture de la page $Page...`r`n$BaseUri"

        $Response = Invoke-FreshserviceGet -Uri $Uri -Headers $Headers
        $Items = @(Get-ResponseCollection -Response $Response -PropertyName $CollectionProperty)

        foreach ($Item in $Items) {
            $Results.Add($Item)
        }

        if ($Items.Count -lt $PerPage) {
            break
        }

        $Page++
    }

    return $Results.ToArray()
}

function Get-ArticleObject {
    param(
        [Parameter(Mandatory)]
        $Response
    )

    $ArticleProperty = $Response.PSObject.Properties['article']

    if ($null -ne $ArticleProperty) {
        return $ArticleProperty.Value
    }

    return $Response
}

# -----------------------------------------------------------------------------
# Acquisition automatique de l'inventaire via Analytics Data Exports
# -----------------------------------------------------------------------------

function Assert-TrustedDownloadUri {
    param([Parameter(Mandatory)][string]$Url)
    $Parsed = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$Parsed) -or $Parsed.Scheme -ne 'https') {
        throw 'Le lien de telechargement du reporting est invalide : HTTPS est obligatoire.'
    }
    $HostName = $Parsed.Host.ToLowerInvariant()
    $Suffixes = @('freshservice.com','freshworks.com','amazonaws.com','cloudfront.net')
    foreach ($Suffix in $Suffixes) {
        if ($HostName -eq $Suffix -or $HostName.EndsWith('.' + $Suffix)) { return }
    }
    throw "Le domaine de telechargement $HostName n'est pas reconnu. Aucun secret ne sera envoye vers ce domaine."
}

function Invoke-InventoryWebDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutputFile,
        [hashtable]$Headers = @{}
    )
    $Attempts = 0
    while ($Attempts -lt 4) {
        $Attempts++
        try {
            Invoke-WebRequest -Uri $Url -Method Get -Headers $Headers -OutFile $OutputFile `
                -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop | Out-Null
            return
        }
        catch {
            $Status = Get-HttpStatusCode -Exception $_.Exception
            if ($Status -in @(429,500,502,503,504) -and $Attempts -lt 4) {
                $Pause = Get-RetryAfterSeconds -Exception $_.Exception -DefaultSeconds (5 * $Attempts)
                Start-Sleep -Seconds $Pause
                continue
            }
            # Les URLs d'export peuvent contenir un jeton d'acces : ne pas afficher la chaine.
            $Detail = if ($Status) { "HTTP $Status" } else { $_.Exception.GetType().Name }
            throw "L'inventaire Analytics n'a pas pu etre telecharge ($Detail). Verifier la configuration Data Exports, l'acces et la date du dernier export. Le mode Manuel reste disponible."
        }
    }
}

function Get-AutomaticReportSource {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$ExportRoot,
        [Parameter(Mandatory)]$ProgressWindow
    )
    $RawFile = Join-Path $ExportRoot '_inventory_download.tmp'
    Update-ProgressWindow -ProgressWindow $ProgressWindow -Message "Recuperation du dernier inventaire depuis Analytics..."
    Invoke-InventoryWebDownload -Url $Configuration.AutomaticUrl -OutputFile $RawFile -Headers $Headers

    for ($Hop = 0; $Hop -lt 3; $Hop++) {
        $Data = [IO.File]::ReadAllBytes($RawFile)
        if ($Data.Length -eq 0) { throw "L'URL API Analytics a renvoye un fichier vide." }
        if ($Data.Length -gt 52428800) { throw 'Inventaire superieur a 50 Mo : controle manuel requis.' }

        # La route Analytics peut retourner un objet JSON pointant vers le CSV.
        $FirstText = [Text.Encoding]::UTF8.GetString($Data, 0, [Math]::Min(400, $Data.Length)).TrimStart([char[]]@([char]0xFEFF, [char]32, [char]13, [char]10, [char]9))
        if ($FirstText.StartsWith('{')) {
            $Payload = $null
            try { $Payload = [Text.Encoding]::UTF8.GetString($Data) | ConvertFrom-Json }
            catch { throw "Le contenu de l'export Analytics n'est pas un JSON lisible." }
            $Link = $null
            $ExportObject = Get-PropertyValue -Object $Payload -PropertyName 'export'
            $DataObject = Get-PropertyValue -Object $Payload -PropertyName 'data'
            $ExportLink = if ($null -ne $ExportObject) { Get-PropertyValue -Object $ExportObject -PropertyName 'url' } else { $null }
            $DataLink = if ($null -ne $DataObject) { Get-PropertyValue -Object $DataObject -PropertyName 'url' } else { $null }
            $DirectLink = Get-PropertyValue -Object $Payload -PropertyName 'download_url'
            $GeneralLink = Get-PropertyValue -Object $Payload -PropertyName 'url'
            if ($ExportLink) { $Link = [string]$ExportLink }
            elseif ($DirectLink) { $Link = [string]$DirectLink }
            elseif ($GeneralLink) { $Link = [string]$GeneralLink }
            elseif ($DataLink) { $Link = [string]$DataLink }
            if (-not $Link) { throw "L'API Analytics ne retourne ni un fichier CSV/XLSX ni une URL de telechargement exploitable." }
            Assert-TrustedDownloadUri -Url $Link
            $LinkUri = [Uri]$Link
            # Aucun header d'authentification sur une URL signee tierce.
            $FollowHeaders = @{}
            if ($LinkUri.Host -ieq $Configuration.Domain) { $FollowHeaders = $Headers }
            Invoke-InventoryWebDownload -Url $Link -OutputFile $RawFile -Headers $FollowHeaders
            continue
        }
        break
    }
    $Data = [IO.File]::ReadAllBytes($RawFile)
    if ($Data.Length -lt 1) { throw "Le telechargement de l'inventaire est vide." }
    $HeaderText = [Text.Encoding]::UTF8.GetString($Data, 0, [Math]::Min(250, $Data.Length)).TrimStart()
    if ($HeaderText.StartsWith('<')) {
        throw "L'URL Analytics a retourne une page HTML (connexion ou page d'erreur) et non un inventaire CSV ou XLSX."
    }
    $IsZip = $Data.Length -gt 4 -and $Data[0] -eq 80 -and $Data[1] -eq 75
    if ($IsZip) {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $Archive = [IO.Compression.ZipFile]::OpenRead($RawFile)
        try {
            $Names = @($Archive.Entries | ForEach-Object { $_.FullName })
            if ($Names -contains '[Content_Types].xml') {
                $Destination = Join-Path $ExportRoot 'report-source-auto.xlsx'
                Copy-Item -LiteralPath $RawFile -Destination $Destination -Force
                return $Destination
            }
            $Candidate = @($Archive.Entries | Where-Object { $_.Name -match '\.(csv|xlsx)$' } | Select-Object -First 1)
            if ($Candidate.Count -eq 0) { throw 'Le ZIP Analytics ne contient aucun fichier CSV ou XLSX.' }
            $Ext = [IO.Path]::GetExtension($Candidate[0].Name).ToLowerInvariant()
            $Destination = Join-Path $ExportRoot ('report-source-auto' + $Ext)
            $InputStream = $Candidate[0].Open()
            try {
                $OutputStream = [IO.File]::Create($Destination)
                try { $InputStream.CopyTo($OutputStream) }
                finally { $OutputStream.Dispose() }
            }
            finally { $InputStream.Dispose() }
            return $Destination
        }
        finally { $Archive.Dispose() }
    }
    if ($HeaderText.StartsWith('{')) { throw "L'URL API Analytics n'a pas retourne de fichier apres les redirections de telechargement." }
    # Pour le mode automatique, l'API Freshservice documente un export CSV.
    # On confirme aussi que la premiere ligne ressemble a un tableau d'inventaire.
    $FirstLine = [Text.Encoding]::UTF8.GetString($Data, 0, [Math]::Min(2000, $Data.Length)) -split '\r?\n' | Select-Object -First 1
    $FirstLineClean = $FirstLine.TrimStart([char]0xFEFF)
    if ($FirstLineClean -notmatch '(?i)(^|[,;\t])\s*"?(id|article[ _]?id|solution[ _]?id)"?\s*([,;\t]|$)') {
        throw "L'inventaire telecharge n'a pas de colonne ID reconnue. Verifier que le Data Export contient les articles de la Knowledge Base."
    }
    $Destination = Join-Path $ExportRoot 'report-source-auto.csv'
    Move-Item -LiteralPath $RawFile -Destination $Destination -Force
    return $Destination
}

# -----------------------------------------------------------------------------
# Lecture du fichier reporting
# -----------------------------------------------------------------------------

function Normalize-ColumnName {
    param(
        [AllowNull()]
        $Name
    )

    if ($null -eq $Name) {
        return ''
    }

    $Text = [string]$Name
    $Decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
    $Builder = New-Object System.Text.StringBuilder

    foreach ($Character in $Decomposed.ToCharArray()) {
        $UnicodeCategory = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($Character)

        if ($UnicodeCategory -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$Builder.Append($Character)
        }
    }

    $Normalized = $Builder.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $Normalized = $Normalized -replace '[^a-z0-9]', ''

    return $Normalized
}

function Get-HeaderMap {
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows
    )

    if ($Rows.Count -eq 0) {
        throw 'Le fichier source ne contient aucune ligne de données.'
    }

    $Properties = @($Rows[0].PSObject.Properties.Name)
    $NormalizedToOriginal = @{}

    foreach ($PropertyName in $Properties) {
        $NormalizedName = Normalize-ColumnName -Name $PropertyName

        if (-not [string]::IsNullOrWhiteSpace($NormalizedName) -and -not $NormalizedToOriginal.ContainsKey($NormalizedName)) {
            $NormalizedToOriginal[$NormalizedName] = $PropertyName
        }
    }

    function Find-HeaderName {
        param(
            [string[]]$Candidates
        )

        foreach ($Candidate in $Candidates) {
            $NormalizedCandidate = Normalize-ColumnName -Name $Candidate

            if ($NormalizedToOriginal.ContainsKey($NormalizedCandidate)) {
                return $NormalizedToOriginal[$NormalizedCandidate]
            }
        }

        return $null
    }

    $Map = [PSCustomObject]@{
        Id           = Find-HeaderName -Candidates @('ID', 'Article ID', 'Solution ID', 'Solution Article ID')
        Title        = Find-HeaderName -Candidates @('Title', 'Article Title', 'Solution Title')
        Type         = Find-HeaderName -Candidates @('Type', 'Article Type')
        Status       = Find-HeaderName -Candidates @('Status', 'Article Status')
        Author       = Find-HeaderName -Candidates @('Author', 'Author Name', 'Created By')
        CreatedDate  = Find-HeaderName -Candidates @('Created Date', 'Created At')
        Category     = Find-HeaderName -Candidates @('Category', 'Category Name')
        Folder       = Find-HeaderName -Candidates @('Folder', 'Folder Name')
        ModifiedDate = Find-HeaderName -Candidates @('Modified Date', 'Modified At', 'Updated Date')
        ReviewDate   = Find-HeaderName -Candidates @('Review Date')
        ViewedBy     = Find-HeaderName -Candidates @('Viewed by Name', 'Viewed By', 'Viewer Name')
        LastUpdated  = Find-HeaderName -Candidates @('Last Updated')
    }

    if ([string]::IsNullOrWhiteSpace([string]$Map.Id)) {
        $AvailableHeaders = $Properties -join ', '
        throw "La colonne contenant l'identifiant des articles est absente.`r`n`r`nUne colonne nommée ID, Article ID ou Solution ID est obligatoire.`r`n`r`nColonnes détectées : $AvailableHeaders"
    }

    return $Map
}

function Get-SourcePropertyValue {
    param(
        [Parameter(Mandatory)]
        $Row,

        [AllowNull()]
        [string]$PropertyName
    )

    if ([string]::IsNullOrWhiteSpace($PropertyName)) {
        return $null
    }

    return Get-PropertyValue -Object $Row -PropertyName $PropertyName
}

function ConvertTo-ArticleId {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double]) {
        try {
            $NumericId = [long][Math]::Truncate([double]$Value)

            if ($NumericId -gt 0) {
                return $NumericId
            }
        }
        catch {
            return $null
        }
    }

    $Text = ([string]$Value).Trim()
    $Match = [regex]::Match($Text, '\d{6,}')

    if ($Match.Success) {
        $ParsedId = 0L

        if ([long]::TryParse($Match.Value, [ref]$ParsedId)) {
            return $ParsedId
        }
    }

    return $null
}

function Convert-SourceDateValue {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToString('yyyy-MM-dd HH:mm:ss')
    }

    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double]) {
        try {
            $Serial = [double]$Value

            if ($Serial -gt 20000 -and $Serial -lt 100000) {
                return [datetime]::FromOADate($Serial).ToString('yyyy-MM-dd HH:mm:ss')
            }
        }
        catch {
            return [string]$Value
        }
    }

    return [string]$Value
}

function Get-CsvDelimiter {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $FirstLine = Get-Content -LiteralPath $Path -TotalCount 1

    if ($null -eq $FirstLine) {
        throw 'Le fichier CSV est vide.'
    }

    $Candidates = @(
        [PSCustomObject]@{ Character = ';'; Count = ([regex]::Matches($FirstLine, ';')).Count },
        [PSCustomObject]@{ Character = ','; Count = ([regex]::Matches($FirstLine, ',')).Count },
        [PSCustomObject]@{ Character = "`t"; Count = ([regex]::Matches($FirstLine, "`t")).Count }
    )

    $Selected = $Candidates | Sort-Object Count -Descending | Select-Object -First 1

    if ($Selected.Count -le 0) {
        throw "Le séparateur du fichier CSV n'a pas pu être identifié. Les séparateurs pris en charge sont le point-virgule, la virgule et la tabulation."
    }

    return [char]$Selected.Character
}

function Read-CsvSourceRows {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Delimiter = Get-CsvDelimiter -Path $Path

    try {
        return @(Import-Csv -LiteralPath $Path -Delimiter $Delimiter -Encoding UTF8)
    }
    catch {
        try {
            return @(Import-Csv -LiteralPath $Path -Delimiter $Delimiter -Encoding Default)
        }
        catch {
            throw "Impossible de lire le fichier CSV.`r`n$($_.Exception.Message)"
        }
    }
}

function Release-ComObject {
    param(
        $ComObject
    )

    if ($null -ne $ComObject) {
        try {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ComObject)
        }
        catch {
            # La libération explicite est une mesure de sécurité, sans bloquer l'export.
        }
    }
}

function Read-XlsxSourceRows {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Excel = $null
    $Workbook = $null
    $Worksheet = $null
    $UsedRange = $null

    try {
        try {
            $Excel = New-Object -ComObject Excel.Application
        }
        catch {
            throw "Microsoft Excel n'est pas disponible pour lire le fichier XLSX. Enregistrer le reporting au format CSV puis relancer le script, ou exécuter le script sur un poste disposant d'Excel."
        }

        $Excel.Visible = $false
        $Excel.DisplayAlerts = $false
        $Workbook = $Excel.Workbooks.Open($Path, 0, $true)
        $Worksheet = $Workbook.Worksheets.Item(1)
        $UsedRange = $Worksheet.UsedRange

        $RowCount = [int]$UsedRange.Rows.Count
        $ColumnCount = [int]$UsedRange.Columns.Count

        if ($RowCount -lt 2 -or $ColumnCount -lt 1) {
            throw "La première feuille du fichier XLSX ne contient pas de tableau exploitable."
        }

        $Values = $UsedRange.Value2
        $Headers = New-Object 'System.Collections.Generic.List[string]'

        for ($Column = 1; $Column -le $ColumnCount; $Column++) {
            $Header = [string]$Values[1, $Column]

            if ([string]::IsNullOrWhiteSpace($Header)) {
                $Header = "Column$Column"
            }

            $OriginalHeader = $Header
            $Suffix = 2

            while ($Headers.Contains($Header)) {
                $Header = "${OriginalHeader}_$Suffix"
                $Suffix++
            }

            $Headers.Add($Header)
        }

        $Rows = New-Object 'System.Collections.Generic.List[object]'

        for ($Row = 2; $Row -le $RowCount; $Row++) {
            $Record = [ordered]@{}
            $HasValue = $false

            for ($Column = 1; $Column -le $ColumnCount; $Column++) {
                $Value = $Values[$Row, $Column]

                if ($null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)) {
                    $HasValue = $true
                }

                $Record[$Headers[$Column - 1]] = $Value
            }

            if ($HasValue) {
                $Rows.Add([PSCustomObject]$Record)
            }
        }

        return $Rows.ToArray()
    }
    finally {
        if ($null -ne $Workbook) {
            try {
                $Workbook.Close($false)
            }
            catch {
                # Aucun traitement complémentaire requis.
            }
        }

        if ($null -ne $Excel) {
            try {
                $Excel.Quit()
            }
            catch {
                # Aucun traitement complémentaire requis.
            }
        }

        Release-ComObject -ComObject $UsedRange
        Release-ComObject -ComObject $Worksheet
        Release-ComObject -ComObject $Workbook
        Release-ComObject -ComObject $Excel
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Read-SourceRows {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()

    switch ($Extension) {
        '.csv' {
            return @(Read-CsvSourceRows -Path $Path)
        }
        '.xlsx' {
            return @(Read-XlsxSourceRows -Path $Path)
        }
        default {
            throw 'Le fichier source doit être au format CSV ou XLSX.'
        }
    }
}

function Get-DeduplicatedSourceArticles {
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        $HeaderMap,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Errors
    )

    $ById = @{}
    $SourceRowNumber = 1

    foreach ($Row in $Rows) {
        $SourceRowNumber++
        $RawId = Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.Id
        $ArticleId = ConvertTo-ArticleId -Value $RawId

        if ($null -eq $ArticleId) {
            $Errors.Add(
                [PSCustomObject]@{
                    Level      = 'SourceRow'
                    SourceRow  = $SourceRowNumber
                    ArticleId  = $RawId
                    Error      = "Identifiant absent ou invalide dans le fichier source."
                }
            )
            continue
        }

        $Key = [string]$ArticleId

        if (-not $ById.ContainsKey($Key)) {
            $ById[$Key] = [PSCustomObject]@{
                ArticleId      = $ArticleId
                Title          = [string](Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.Title)
                Type           = [string](Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.Type)
                Status         = [string](Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.Status)
                Author         = [string](Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.Author)
                CreatedDate    = Convert-SourceDateValue -Value (Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.CreatedDate)
                Category       = [string](Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.Category)
                Folder         = [string](Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.Folder)
                ModifiedDate   = Convert-SourceDateValue -Value (Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.ModifiedDate)
                ReviewDate     = Convert-SourceDateValue -Value (Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.ReviewDate)
                LastUpdated    = Convert-SourceDateValue -Value (Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.LastUpdated)
                SourceRowCount = 0
                ViewedBySet    = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
            }
        }

        $Entry = $ById[$Key]
        $Entry.SourceRowCount++

        $ViewedBy = [string](Get-SourcePropertyValue -Row $Row -PropertyName $HeaderMap.ViewedBy)

        if (-not [string]::IsNullOrWhiteSpace($ViewedBy)) {
            [void]$Entry.ViewedBySet.Add($ViewedBy.Trim())
        }
    }

    $Result = New-Object 'System.Collections.Generic.List[object]'

    foreach ($Entry in ($ById.Values | Sort-Object ArticleId)) {
        $ViewedByNames = @($Entry.ViewedBySet) -join '; '

        $Result.Add(
            [PSCustomObject]@{
                ArticleId      = $Entry.ArticleId
                Title          = $Entry.Title
                Type           = $Entry.Type
                Status         = $Entry.Status
                Author         = $Entry.Author
                CreatedDate    = $Entry.CreatedDate
                Category       = $Entry.Category
                Folder         = $Entry.Folder
                ModifiedDate   = $Entry.ModifiedDate
                ReviewDate     = $Entry.ReviewDate
                LastUpdated    = $Entry.LastUpdated
                SourceRowCount = $Entry.SourceRowCount
                ViewedByNames  = $ViewedByNames
            }
        )
    }

    return $Result.ToArray()
}

# -----------------------------------------------------------------------------
# Référentiels catégories et dossiers
# -----------------------------------------------------------------------------

function Get-FolderHierarchyInfo {
    param(
        [AllowNull()]
        $FolderId,

        [Parameter(Mandatory)]
        [hashtable]$FolderById,

        [Parameter(Mandatory)]
        [hashtable]$CategoryById
    )

    if ($null -eq $FolderId) {
        return [PSCustomObject]@{
            FolderId      = $null
            FolderName    = ''
            FolderPath    = ''
            CategoryId    = $null
            CategoryName  = ''
            WorkspaceId   = $null
        }
    }

    $FolderKey = [string]$FolderId

    if (-not $FolderById.ContainsKey($FolderKey)) {
        return [PSCustomObject]@{
            FolderId      = $FolderId
            FolderName    = ''
            FolderPath    = ''
            CategoryId    = $null
            CategoryName  = ''
            WorkspaceId   = $null
        }
    }

    $Folder = $FolderById[$FolderKey]
    $FolderName = [string](Get-PropertyValue -Object $Folder -PropertyName 'name')
    $CategoryId = Get-PropertyValue -Object $Folder -PropertyName 'category_id'
    $WorkspaceId = Get-PropertyValue -Object $Folder -PropertyName 'workspace_id'

    $Segments = New-Object 'System.Collections.Generic.List[string]'
    $Visited = New-Object 'System.Collections.Generic.HashSet[string]'
    $Current = $Folder

    while ($null -ne $Current) {
        $CurrentId = Get-PropertyValue -Object $Current -PropertyName 'id'
        $CurrentKey = [string]$CurrentId

        if ($Visited.Contains($CurrentKey)) {
            break
        }

        [void]$Visited.Add($CurrentKey)
        $CurrentName = [string](Get-PropertyValue -Object $Current -PropertyName 'name')

        if (-not [string]::IsNullOrWhiteSpace($CurrentName)) {
            $Segments.Insert(0, $CurrentName)
        }

        $ParentId = Get-PropertyValue -Object $Current -PropertyName 'parent_id'

        if ($null -eq $ParentId -or [string]::IsNullOrWhiteSpace([string]$ParentId) -or [long]$ParentId -eq 0) {
            break
        }

        $ParentKey = [string]$ParentId

        if (-not $FolderById.ContainsKey($ParentKey)) {
            break
        }

        $Current = $FolderById[$ParentKey]
    }

    $CategoryName = ''
    $CategoryKey = [string]$CategoryId

    if (-not [string]::IsNullOrWhiteSpace($CategoryKey) -and $CategoryById.ContainsKey($CategoryKey)) {
        $CategoryName = [string](Get-PropertyValue -Object $CategoryById[$CategoryKey] -PropertyName 'name')
    }

    return [PSCustomObject]@{
        FolderId      = $FolderId
        FolderName    = $FolderName
        FolderPath    = ($Segments.ToArray() -join ' > ')
        CategoryId    = $CategoryId
        CategoryName  = $CategoryName
        WorkspaceId   = $WorkspaceId
    }
}

function Find-FolderFromSourceNames {
    param(
        [AllowEmptyString()]
        [string]$SourceCategory,

        [AllowEmptyString()]
        [string]$SourceFolder,

        [Parameter(Mandatory)]
        [object[]]$Folders,

        [Parameter(Mandatory)]
        [hashtable]$CategoryById
    )

    if ([string]::IsNullOrWhiteSpace($SourceFolder)) {
        return $null
    }

    $FolderMatches = @(
        $Folders | Where-Object {
            ([string](Get-PropertyValue -Object $_ -PropertyName 'name')).Trim().Equals(
                $SourceFolder.Trim(),
                [StringComparison]::OrdinalIgnoreCase
            )
        }
    )

    if ($FolderMatches.Count -eq 1) {
        return $FolderMatches[0]
    }

    if ($FolderMatches.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($SourceCategory)) {
        foreach ($Folder in $FolderMatches) {
            $CategoryId = Get-PropertyValue -Object $Folder -PropertyName 'category_id'
            $CategoryKey = [string]$CategoryId

            if ($CategoryById.ContainsKey($CategoryKey)) {
                $CategoryName = [string](Get-PropertyValue -Object $CategoryById[$CategoryKey] -PropertyName 'name')

                if ($CategoryName.Trim().Equals($SourceCategory.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
                    return $Folder
                }
            }
        }
    }

    return $null
}

# -----------------------------------------------------------------------------
# Fichiers de sortie
# -----------------------------------------------------------------------------

function ConvertTo-SafeFileName {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [int]$MaxLength = 80
    )

    $SafeName = $Name.Trim()

    foreach ($InvalidCharacter in [IO.Path]::GetInvalidFileNameChars()) {
        $SafeName = $SafeName.Replace([string]$InvalidCharacter, '_')
    }

    $SafeName = $SafeName -replace '\s+', ' '
    $SafeName = $SafeName.Trim().TrimEnd('.')

    if ([string]::IsNullOrWhiteSpace($SafeName)) {
        $SafeName = 'Unnamed'
    }

    $ReservedNames = @(
        'CON', 'PRN', 'AUX', 'NUL',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
    )

    if ($ReservedNames -contains $SafeName.ToUpperInvariant()) {
        $SafeName = "_$SafeName"
    }

    if ($SafeName.Length -gt $MaxLength) {
        $SafeName = $SafeName.Substring(0, $MaxLength).TrimEnd()
    }

    return $SafeName
}

function Get-PathSafeFileBaseName {
    param(
        [Parameter(Mandatory)]
        [string]$ParentPath,

        [Parameter(Mandatory)]
        $Id,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Title,

        [int]$PreferredTitleLength = 48,

        [int]$MaximumFullPathLength = 240
    )

    $IdText = [string]$Id
    $LongestExtensionLength = 5
    $FixedLength = $ParentPath.Length + 1 + $IdText.Length + 1 + $LongestExtensionLength
    $AvailableTitleLength = $MaximumFullPathLength - $FixedLength

    if ($AvailableTitleLength -le 0) {
        return $IdText
    }

    $TitleLength = [Math]::Min($PreferredTitleLength, $AvailableTitleLength)
    $SafeTitle = ConvertTo-SafeFileName -Name $Title -MaxLength $TitleLength

    if ([string]::IsNullOrWhiteSpace($SafeTitle)) {
        return $IdText
    }

    return "${IdText}_${SafeTitle}"
}

function Get-RelativeExportPath {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [string]$FullPath
    )

    $NormalizedRoot = [IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
    $NormalizedFull = [IO.Path]::GetFullPath($FullPath)

    if ($NormalizedFull.StartsWith($NormalizedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $NormalizedFull.Substring($NormalizedRoot.Length).TrimStart([char[]]'\/')
    }

    return $NormalizedFull
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]
        $Data,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $Json = ConvertTo-Json -InputObject $Data -Depth 100
    Set-Content -LiteralPath $Path -Value $Json -Encoding UTF8
}

function Add-ExportLog {
    param(
        [Parameter(Mandatory)]
        [string]$LogPath,

        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $Line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
}

function New-ArticleHtmlDocument {
    param(
        [Parameter(Mandatory)]
        $Article,

        [Parameter(Mandatory)]
        $SourceArticle,

        [Parameter(Mandatory)]
        [string]$CategoryName,

        [Parameter(Mandatory)]
        [string]$FolderName,

        [Parameter(Mandatory)]
        [string]$FolderPath,

        [Parameter(Mandatory)]
        [string]$FreshserviceLink
    )

    $ApiTitle = [string](Get-PropertyValue -Object $Article -PropertyName 'title')
    $RawTitle = if ([string]::IsNullOrWhiteSpace($ApiTitle)) { [string]$SourceArticle.Title } else { $ApiTitle }
    $Title = [System.Net.WebUtility]::HtmlEncode($RawTitle)

    $DescriptionHtml = Get-PropertyValue -Object $Article -PropertyName 'description'
    $DescriptionText = [string](Get-PropertyValue -Object $Article -PropertyName 'description_text')
    $ExternalUrl = [string](Get-PropertyValue -Object $Article -PropertyName 'url')

    if ([string]::IsNullOrWhiteSpace([string]$DescriptionHtml)) {
        if (-not [string]::IsNullOrWhiteSpace($DescriptionText)) {
            $DescriptionHtml = [System.Net.WebUtility]::HtmlEncode($DescriptionText) -replace "`r?`n", '<br>'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ExternalUrl)) {
            $EncodedUrl = [System.Net.WebUtility]::HtmlEncode($ExternalUrl)
            $DescriptionHtml = '<p><a href="{0}" target="_blank">Ouvrir la ressource externe</a></p>' -f $EncodedUrl
        }
        else {
            $DescriptionHtml = "<p>Aucun contenu textuel n'a été retourné par l'API.</p>"
        }
    }

    $ArticleId = Get-PropertyValue -Object $Article -PropertyName 'id'
    $ApiStatus = Get-PropertyValue -Object $Article -PropertyName 'status'
    $ApiArticleType = Get-PropertyValue -Object $Article -PropertyName 'article_type'
    $CreatedAt = Get-PropertyValue -Object $Article -PropertyName 'created_at'
    $UpdatedAt = Get-PropertyValue -Object $Article -PropertyName 'updated_at'
    $ModifiedAt = Get-PropertyValue -Object $Article -PropertyName 'modified_at'
    $WorkspaceId = Get-PropertyValue -Object $Article -PropertyName 'workspace_id'

    $CategoryEncoded = [System.Net.WebUtility]::HtmlEncode($CategoryName)
    $FolderEncoded = [System.Net.WebUtility]::HtmlEncode($FolderName)
    $FolderPathEncoded = [System.Net.WebUtility]::HtmlEncode($FolderPath)
    $FreshserviceLinkEncoded = [System.Net.WebUtility]::HtmlEncode($FreshserviceLink)
    $SourceTypeEncoded = [System.Net.WebUtility]::HtmlEncode([string]$SourceArticle.Type)
    $SourceStatusEncoded = [System.Net.WebUtility]::HtmlEncode([string]$SourceArticle.Status)
    $SourceAuthorEncoded = [System.Net.WebUtility]::HtmlEncode([string]$SourceArticle.Author)

    return @"
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>$Title</title>
    <style>
        body {
            font-family: "Segoe UI", Arial, sans-serif;
            max-width: 1100px;
            margin: 40px auto;
            line-height: 1.55;
            padding: 0 24px;
            color: #222;
        }
        .metadata {
            background: #f3f5f7;
            border: 1px solid #d7dce1;
            border-radius: 6px;
            padding: 16px;
            margin-bottom: 24px;
        }
        .metadata p {
            margin: 4px 0;
        }
        img {
            max-width: 100%;
            height: auto;
        }
        table {
            border-collapse: collapse;
            max-width: 100%;
        }
        th, td {
            border: 1px solid #cccccc;
            padding: 7px;
            vertical-align: top;
        }
        pre, code {
            white-space: pre-wrap;
            overflow-wrap: anywhere;
        }
    </style>
</head>
<body>
    <h1>$Title</h1>

    <div class="metadata">
        <p><strong>Article ID :</strong> $ArticleId</p>
        <p><strong>Lien Freshservice :</strong> <a href="$FreshserviceLinkEncoded" target="_blank">Ouvrir l'article</a></p>
        <p><strong>Catégorie :</strong> $CategoryEncoded</p>
        <p><strong>Dossier :</strong> $FolderEncoded</p>
        <p><strong>Chemin du dossier :</strong> $FolderPathEncoded</p>
        <p><strong>Type (reporting) :</strong> $SourceTypeEncoded</p>
        <p><strong>Statut (reporting) :</strong> $SourceStatusEncoded</p>
        <p><strong>Auteur (reporting) :</strong> $SourceAuthorEncoded</p>
        <p><strong>Workspace ID :</strong> $WorkspaceId</p>
        <p><strong>Statut API :</strong> $ApiStatus</p>
        <p><strong>Type API :</strong> $ApiArticleType</p>
        <p><strong>Créé le :</strong> $CreatedAt</p>
        <p><strong>Mis à jour le :</strong> $UpdatedAt</p>
        <p><strong>Modifié le :</strong> $ModifiedAt</p>
    </div>

    <main>
        $DescriptionHtml
    </main>
</body>
</html>
"@
}

function Export-ObjectsToXlsx {
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$WorksheetName = 'Articles'
    )

    if ($Rows.Count -eq 0) {
        return $false
    }

    $Excel = $null
    $Workbook = $null
    $Worksheet = $null
    $Range = $null

    try {
        try {
            $Excel = New-Object -ComObject Excel.Application
        }
        catch {
            return $false
        }

        $Excel.Visible = $false
        $Excel.DisplayAlerts = $false
        $Workbook = $Excel.Workbooks.Add()
        $Worksheet = $Workbook.Worksheets.Item(1)
        $Worksheet.Name = $WorksheetName.Substring(0, [Math]::Min(31, $WorksheetName.Length))

        $Headers = @($Rows[0].PSObject.Properties.Name)
        $RowCount = $Rows.Count + 1
        $ColumnCount = $Headers.Count
        $Data = New-Object 'object[,]' $RowCount, $ColumnCount

        for ($Column = 0; $Column -lt $ColumnCount; $Column++) {
            $Data[0, $Column] = $Headers[$Column]
        }

        for ($RowIndex = 0; $RowIndex -lt $Rows.Count; $RowIndex++) {
            for ($Column = 0; $Column -lt $ColumnCount; $Column++) {
                $Data[$RowIndex + 1, $Column] = Get-PropertyValue -Object $Rows[$RowIndex] -PropertyName $Headers[$Column]
            }
        }

        $StartCell = $Worksheet.Cells.Item(1, 1)
        $EndCell = $Worksheet.Cells.Item($RowCount, $ColumnCount)
        $Range = $Worksheet.Range($StartCell, $EndCell)
        $Range.Value2 = $Data

        $HeaderRange = $Worksheet.Range($Worksheet.Cells.Item(1, 1), $Worksheet.Cells.Item(1, $ColumnCount))
        $HeaderRange.Font.Bold = $true
        $HeaderRange.Interior.ColorIndex = 15
        $HeaderRange.AutoFilter() | Out-Null
        $Worksheet.Application.ActiveWindow.SplitRow = 1
        $Worksheet.Application.ActiveWindow.FreezePanes = $true
        $Worksheet.Columns.AutoFit() | Out-Null

        for ($Column = 1; $Column -le $ColumnCount; $Column++) {
            if ($Worksheet.Columns.Item($Column).ColumnWidth -gt 45) {
                $Worksheet.Columns.Item($Column).ColumnWidth = 45
            }
        }

        $Workbook.SaveAs($Path, 51)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $Workbook) {
            try {
                $Workbook.Close($false)
            }
            catch {
                # Aucun traitement complémentaire requis.
            }
        }

        if ($null -ne $Excel) {
            try {
                $Excel.Quit()
            }
            catch {
                # Aucun traitement complémentaire requis.
            }
        }

        Release-ComObject -ComObject $Range
        Release-ComObject -ComObject $Worksheet
        Release-ComObject -ComObject $Workbook
        Release-ComObject -ComObject $Excel
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

# -----------------------------------------------------------------------------
# Export principal
# -----------------------------------------------------------------------------

function Export-FreshserviceKnowledgeBaseFromReport {
    param(
        [Parameter(Mandatory)]
        $Configuration,

        [Parameter(Mandatory)]
        $ProgressWindow
    )

    $PerPage = 100
    $Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $ExportFolderName = "Freshservice-KB-Report-Export-$Timestamp"
    $ExportRoot = Join-Path -Path $Configuration.ExportPath -ChildPath $ExportFolderName
    New-Item -ItemType Directory -Path $ExportRoot -Force | Out-Null

    $script:CurrentExportRoot = $ExportRoot
    $LogPath = Join-Path -Path $ExportRoot -ChildPath 'export.log'
    Set-Content -LiteralPath $LogPath -Value 'Freshservice Knowledge Base export from reporting' -Encoding UTF8

    $CredentialsText = '{0}:{1}' -f $Configuration.ApiKey, $Configuration.BasicPassword
    $BasicAuthValue = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($CredentialsText))
    $Headers = @{
        Authorization = "Basic $BasicAuthValue"
        Accept        = 'application/json'
    }

    $ApiBase = "https://$($Configuration.Domain)/api/v2/solutions"
    Add-ExportLog -LogPath $LogPath -Message "Début de l'export depuis $ApiBase"
    if ($Configuration.SourceMode -eq 'Automatic') {
        # Ne jamais consigner l'URL Analytics : elle peut contenir un jeton d'acces.
        Add-ExportLog -LogPath $LogPath -Message 'Source : dernier Data Export Analytics via URL API.'
        $Configuration.SourceFile = Get-AutomaticReportSource -Configuration $Configuration -Headers $Headers `
            -ExportRoot $ExportRoot -ProgressWindow $ProgressWindow
    }
    else {
        Add-ExportLog -LogPath $LogPath -Message "Source : reporting local $($Configuration.SourceFile)"
    }

    $ExportErrors = New-Object 'System.Collections.Generic.List[object]'
    $ArticleResults = New-Object 'System.Collections.Generic.List[object]'
    $CompleteArticles = New-Object 'System.Collections.Generic.List[object]'

    Update-ProgressWindow -ProgressWindow $ProgressWindow -Message 'Lecture du fichier reporting...'
    $SourceRows = @(Read-SourceRows -Path $Configuration.SourceFile)

    if ($SourceRows.Count -eq 0) {
        throw 'Le fichier reporting ne contient aucune ligne de données.'
    }

    $HeaderMap = Get-HeaderMap -Rows $SourceRows
    $SourceArticles = @(Get-DeduplicatedSourceArticles -Rows $SourceRows -HeaderMap $HeaderMap -Errors $ExportErrors)

    if ($SourceArticles.Count -eq 0) {
        throw "Aucun ID d'article valide n'a été trouvé dans le fichier reporting."
    }

    Add-ExportLog -LogPath $LogPath -Message "Lignes source : $($SourceRows.Count). Articles uniques après déduplication : $($SourceArticles.Count)."

    $SourceCleanCsvPath = Join-Path -Path $ExportRoot -ChildPath 'source-deduplicated.csv'
    $SourceArticles | Export-Csv -LiteralPath $SourceCleanCsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8

    Update-ProgressWindow -ProgressWindow $ProgressWindow -Message 'Récupération des catégories Freshservice...'
    $Categories = @(
        Get-FreshservicePagedCollection `
            -BaseUri "$ApiBase/categories" `
            -CollectionProperty 'categories' `
            -Headers $Headers `
            -PerPage $PerPage `
            -ProgressWindow $ProgressWindow
    )

    Update-ProgressWindow -ProgressWindow $ProgressWindow -Message 'Récupération de tous les dossiers Freshservice...'
    $Folders = @(
        Get-FreshservicePagedCollection `
            -BaseUri "$ApiBase/folders" `
            -CollectionProperty 'folders' `
            -Headers $Headers `
            -PerPage $PerPage `
            -ProgressWindow $ProgressWindow
    )

    Add-ExportLog -LogPath $LogPath -Message "Catégories récupérées : $($Categories.Count). Dossiers récupérés : $($Folders.Count)."

    Write-JsonFile -Data $Categories -Path (Join-Path -Path $ExportRoot -ChildPath 'categories.json')
    Write-JsonFile -Data $Folders -Path (Join-Path -Path $ExportRoot -ChildPath 'folders.json')

    $CategoryById = @{}
    foreach ($Category in $Categories) {
        $CategoryId = Get-PropertyValue -Object $Category -PropertyName 'id'

        if ($null -ne $CategoryId) {
            $CategoryById[[string]$CategoryId] = $Category
        }
    }

    $FolderById = @{}
    foreach ($Folder in $Folders) {
        $FolderId = Get-PropertyValue -Object $Folder -PropertyName 'id'

        if ($null -ne $FolderId) {
            $FolderById[[string]$FolderId] = $Folder
        }
    }

    $ArticlesRoot = Join-Path -Path $ExportRoot -ChildPath 'Articles'
    New-Item -ItemType Directory -Path $ArticlesRoot -Force | Out-Null

    $ArticleNumber = 0

    foreach ($SourceArticle in $SourceArticles) {
        $ArticleNumber++
        $ArticleId = $SourceArticle.ArticleId
        $FreshserviceLink = "https://$($Configuration.Domain)/a/solutions/articles/$ArticleId"

        Update-ProgressWindow `
            -ProgressWindow $ProgressWindow `
            -Message "Article $ArticleNumber/$($SourceArticles.Count)`r`nID : $ArticleId — $($SourceArticle.Title)"

        try {
            $DetailResponse = Invoke-FreshserviceGet -Uri "$ApiBase/articles/$ArticleId" -Headers $Headers
            $Article = Get-ArticleObject -Response $DetailResponse
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            $ExportErrors.Add(
                [PSCustomObject]@{
                    Level      = 'ArticleApi'
                    SourceRow  = $null
                    ArticleId  = $ArticleId
                    Error      = $ErrorMessage
                }
            )

            Add-ExportLog -LogPath $LogPath -Level 'ERROR' -Message "Échec de lecture de l'article $ArticleId : $ErrorMessage"

            $ArticleResults.Add(
                [PSCustomObject]@{
                    ID                = $ArticleId
                    FreshserviceLink  = $FreshserviceLink
                    Title             = $SourceArticle.Title
                    Type              = $SourceArticle.Type
                    Status            = $SourceArticle.Status
                    Author            = $SourceArticle.Author
                    CategoryId        = $null
                    Category          = $SourceArticle.Category
                    FolderId          = $null
                    Folder            = $SourceArticle.Folder
                    FolderPath        = $SourceArticle.Folder
                    WorkspaceId       = $null
                    CreatedDate       = $SourceArticle.CreatedDate
                    ModifiedDate      = $SourceArticle.ModifiedDate
                    ReviewDate        = $SourceArticle.ReviewDate
                    ApiResult         = 'Error'
                    ApiStatusCode     = Get-HttpStatusCode -Exception $_.Exception
                    ApiTitle          = $null
                    ApiStatus         = $null
                    ApiArticleType    = $null
                    ApiCreatedAt      = $null
                    ApiUpdatedAt      = $null
                    ApiModifiedAt     = $null
                    SourceRowCount    = $SourceArticle.SourceRowCount
                    ViewedByNames     = $SourceArticle.ViewedByNames
                    HtmlFile          = $null
                    JsonFile          = $null
                    Error             = $ErrorMessage
                }
            )

            continue
        }

        $ApiArticleId = Get-PropertyValue -Object $Article -PropertyName 'id'
        if ($null -eq $ApiArticleId) {
            $ApiArticleId = $ArticleId
        }

        $FolderId = Get-PropertyValue -Object $Article -PropertyName 'folder_id'

        if ($null -eq $FolderId) {
            $MatchedFolder = Find-FolderFromSourceNames `
                -SourceCategory $SourceArticle.Category `
                -SourceFolder $SourceArticle.Folder `
                -Folders $Folders `
                -CategoryById $CategoryById

            if ($null -ne $MatchedFolder) {
                $FolderId = Get-PropertyValue -Object $MatchedFolder -PropertyName 'id'
            }
        }

        $Hierarchy = Get-FolderHierarchyInfo `
            -FolderId $FolderId `
            -FolderById $FolderById `
            -CategoryById $CategoryById

        $CategoryName = $Hierarchy.CategoryName
        if ([string]::IsNullOrWhiteSpace($CategoryName)) {
            $CategoryName = $SourceArticle.Category
        }
        if ([string]::IsNullOrWhiteSpace($CategoryName)) {
            $CategoryName = 'Uncategorized'
        }

        $FolderName = $Hierarchy.FolderName
        if ([string]::IsNullOrWhiteSpace($FolderName)) {
            $FolderName = $SourceArticle.Folder
        }
        if ([string]::IsNullOrWhiteSpace($FolderName)) {
            $FolderName = 'Unassigned folder'
        }

        $FolderPath = $Hierarchy.FolderPath
        if ([string]::IsNullOrWhiteSpace($FolderPath)) {
            $FolderPath = $FolderName
        }

        $CategoryIdText = if ($null -eq $Hierarchy.CategoryId) { 'NoCategoryId' } else { [string]$Hierarchy.CategoryId }
        $FolderIdText = if ($null -eq $FolderId) { 'NoFolderId' } else { [string]$FolderId }
        $SafeCategoryName = ConvertTo-SafeFileName -Name $CategoryName -MaxLength 42
        $SafeFolderName = ConvertTo-SafeFileName -Name $FolderName -MaxLength 42

        $CategoryDirectory = Join-Path -Path $ArticlesRoot -ChildPath ("{0}_{1}" -f $CategoryIdText, $SafeCategoryName)
        $FolderDirectory = Join-Path -Path $CategoryDirectory -ChildPath ("{0}_{1}" -f $FolderIdText, $SafeFolderName)
        New-Item -ItemType Directory -Path $FolderDirectory -Force | Out-Null

        $ApiTitle = [string](Get-PropertyValue -Object $Article -PropertyName 'title')
        $FinalTitle = if ([string]::IsNullOrWhiteSpace($ApiTitle)) { $SourceArticle.Title } else { $ApiTitle }
        if ([string]::IsNullOrWhiteSpace($FinalTitle)) {
            $FinalTitle = "Article-$ArticleId"
        }

        $FileBaseName = Get-PathSafeFileBaseName `
            -ParentPath $FolderDirectory `
            -Id $ArticleId `
            -Title $FinalTitle `
            -PreferredTitleLength 48 `
            -MaximumFullPathLength 240

        $JsonPath = Join-Path -Path $FolderDirectory -ChildPath "$FileBaseName.json"
        $HtmlPath = Join-Path -Path $FolderDirectory -ChildPath "$FileBaseName.html"

        try {
            Write-JsonFile -Data $Article -Path $JsonPath

            $HtmlDocument = New-ArticleHtmlDocument `
                -Article $Article `
                -SourceArticle $SourceArticle `
                -CategoryName $CategoryName `
                -FolderName $FolderName `
                -FolderPath $FolderPath `
                -FreshserviceLink $FreshserviceLink

            Set-Content -LiteralPath $HtmlPath -Value $HtmlDocument -Encoding UTF8
        }
        catch {
            $FileError = $_.Exception.Message
            $ExportErrors.Add(
                [PSCustomObject]@{
                    Level      = 'ArticleFile'
                    SourceRow  = $null
                    ArticleId  = $ArticleId
                    Error      = $FileError
                }
            )

            Add-ExportLog -LogPath $LogPath -Level 'ERROR' -Message "Échec d'écriture des fichiers de l'article $ArticleId : $FileError"
            $HtmlPath = $null
            $JsonPath = $null
        }

        $CompleteArticles.Add(
            [PSCustomObject]@{
                source       = $SourceArticle
                category_id  = $Hierarchy.CategoryId
                category     = $CategoryName
                folder_id    = $FolderId
                folder       = $FolderName
                folder_path  = $FolderPath
                article      = $Article
            }
        )

        $ArticleResults.Add(
            [PSCustomObject]@{
                ID                = $ArticleId
                FreshserviceLink  = $FreshserviceLink
                Title             = $FinalTitle
                Type              = $SourceArticle.Type
                Status            = $SourceArticle.Status
                Author            = $SourceArticle.Author
                CategoryId        = $Hierarchy.CategoryId
                Category          = $CategoryName
                FolderId          = $FolderId
                Folder            = $FolderName
                FolderPath        = $FolderPath
                WorkspaceId       = Get-PropertyValue -Object $Article -PropertyName 'workspace_id'
                CreatedDate       = $SourceArticle.CreatedDate
                ModifiedDate      = $SourceArticle.ModifiedDate
                ReviewDate        = $SourceArticle.ReviewDate
                ApiResult         = 'Success'
                ApiStatusCode     = 200
                ApiTitle          = $ApiTitle
                ApiStatus         = Get-PropertyValue -Object $Article -PropertyName 'status'
                ApiArticleType    = Get-PropertyValue -Object $Article -PropertyName 'article_type'
                ApiCreatedAt      = Get-PropertyValue -Object $Article -PropertyName 'created_at'
                ApiUpdatedAt      = Get-PropertyValue -Object $Article -PropertyName 'updated_at'
                ApiModifiedAt     = Get-PropertyValue -Object $Article -PropertyName 'modified_at'
                SourceRowCount    = $SourceArticle.SourceRowCount
                ViewedByNames     = $SourceArticle.ViewedByNames
                HtmlFile          = if ($null -eq $HtmlPath) { $null } else { Get-RelativeExportPath -RootPath $ExportRoot -FullPath $HtmlPath }
                JsonFile          = if ($null -eq $JsonPath) { $null } else { Get-RelativeExportPath -RootPath $ExportRoot -FullPath $JsonPath }
                Error             = $null
            }
        )

        Start-Sleep -Milliseconds 80
    }

    Update-ProgressWindow -ProgressWindow $ProgressWindow -Message 'Création des inventaires consolidés...'

    $CleanCsvPath = Join-Path -Path $ExportRoot -ChildPath 'articles-clean.csv'
    $CleanXlsxPath = Join-Path -Path $ExportRoot -ChildPath 'articles-clean.xlsx'
    $CompleteJsonPath = Join-Path -Path $ExportRoot -ChildPath 'articles-complete.json'
    $ErrorsPath = Join-Path -Path $ExportRoot -ChildPath 'export-errors.csv'

    $ArticleResults.ToArray() | Export-Csv -LiteralPath $CleanCsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Write-JsonFile -Data $CompleteArticles.ToArray() -Path $CompleteJsonPath

    $XlsxCreated = Export-ObjectsToXlsx -Rows $ArticleResults.ToArray() -Path $CleanXlsxPath -WorksheetName 'Articles clean'
    if (-not $XlsxCreated) {
        Add-ExportLog -LogPath $LogPath -Level 'WARNING' -Message "Le fichier articles-clean.xlsx n'a pas été généré, car Microsoft Excel n'était pas disponible. Le fichier CSV reste disponible."
    }

    if ($ExportErrors.Count -gt 0) {
        $ExportErrors.ToArray() | Export-Csv -LiteralPath $ErrorsPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
    }

    $SuccessCount = @($ArticleResults | Where-Object { $_.ApiResult -eq 'Success' }).Count
    $FailureCount = @($ArticleResults | Where-Object { $_.ApiResult -eq 'Error' }).Count

    Add-ExportLog -LogPath $LogPath -Message "Export terminé. Lignes source : $($SourceRows.Count), ID uniques : $($SourceArticles.Count), succès API : $SuccessCount, échecs API : $FailureCount, erreurs totales : $($ExportErrors.Count)."

    $Configuration.ApiKey = $null
    $Configuration.BasicPassword = $null
    $CredentialsText = $null
    $BasicAuthValue = $null
    $Headers = $null

    return [PSCustomObject]@{
        ExportRoot       = $ExportRoot
        SourceRowCount   = $SourceRows.Count
        UniqueIdCount    = $SourceArticles.Count
        CategoryCount    = $Categories.Count
        FolderCount      = $Folders.Count
        SuccessCount     = $SuccessCount
        FailureCount     = $FailureCount
        ErrorCount       = $ExportErrors.Count
        XlsxCreated      = $XlsxCreated
    }
}

# -----------------------------------------------------------------------------
# Exécution
# -----------------------------------------------------------------------------

$Configuration = $null
$ProgressWindow = $null

try {
    $Configuration = Get-ExportConfiguration

    if ($null -eq $Configuration) {
        exit 0
    }

    # La sauvegarde est optionnelle. Ne jamais la tenter si la case est decochee.
    # L'echec d'ecriture ou de chiffrement ne bloque jamais l'extraction des articles.
    if ($Configuration.RememberConfiguration) {
        try {
            $SaveWarnings = @(Save-FreshserviceSettings -Configuration $Configuration)
            if ($SaveWarnings.Count -gt 0) {
                Show-WarningMessage -Title 'Memorisation partielle' -Message ((@($SaveWarnings) -join "`r`n") + "`r`n`r`nL'export peut continuer sans enregistrer ces informations.")
            }
        }
        catch {
            Show-WarningMessage -Title 'Preferences non sauvegardees' -Message ("Impossible d'enregistrer les preferences :`r`n" + $_.Exception.Message + "`r`n`r`nL'export peut continuer.")
        }
    }
    else {
        try { Clear-FreshserviceSettings }
        catch {
            Show-WarningMessage -Title 'Anciennes preferences non supprimees' -Message ("Impossible d'effacer la configuration precedente :`r`n" + $_.Exception.Message + "`r`n`r`nL'export peut continuer.")
        }
    }

    $ProgressWindow = New-ProgressWindow
    $Result = Export-FreshserviceKnowledgeBaseFromReport `
        -Configuration $Configuration `
        -ProgressWindow $ProgressWindow

    Close-ProgressWindow -ProgressWindow $ProgressWindow
    $ProgressWindow = $null

    $XlsxMessage = if ($Result.XlsxCreated) {
        'Les inventaires CSV et XLSX ont été générés.'
    }
    else {
        "L'inventaire CSV a été généré. Le fichier XLSX n'a pas pu être créé car Microsoft Excel n'était pas disponible."
    }

    if ($Result.FailureCount -eq 0 -and $Result.ErrorCount -eq 0) {
        $Message = @"
Export terminé avec succès.

Lignes du reporting : $($Result.SourceRowCount)
ID uniques : $($Result.UniqueIdCount)
Catégories : $($Result.CategoryCount)
Dossiers : $($Result.FolderCount)
Articles exportés : $($Result.SuccessCount)

$XlsxMessage

Dossier :
$($Result.ExportRoot)
"@

        Show-InformationMessage -Message $Message -Title 'Export Freshservice terminé'
    }
    else {
        $Message = @"
Export terminé avec des avertissements.

Lignes du reporting : $($Result.SourceRowCount)
ID uniques : $($Result.UniqueIdCount)
Catégories : $($Result.CategoryCount)
Dossiers : $($Result.FolderCount)
Articles exportés : $($Result.SuccessCount)
Articles en erreur : $($Result.FailureCount)
Erreurs consignées : $($Result.ErrorCount)

$XlsxMessage

Dossier :
$($Result.ExportRoot)

Le détail est disponible dans export-errors.csv et export.log.
"@

        Show-WarningMessage -Message $Message -Title 'Export Freshservice terminé avec avertissements'
    }

    if ($Configuration.OpenFolder -and (Test-Path -LiteralPath $Result.ExportRoot -PathType Container)) {
        Start-Process -FilePath $Result.ExportRoot
    }
}
catch {
    Close-ProgressWindow -ProgressWindow $ProgressWindow
    $ProgressWindow = $null

    $ErrorMessage = "L'export a échoué.`r`n`r`n$($_.Exception.Message)"

    if (
        -not [string]::IsNullOrWhiteSpace([string]$script:CurrentExportRoot) -and
        (Test-Path -LiteralPath $script:CurrentExportRoot -PathType Container)
    ) {
        $ErrorMessage += "`r`n`r`nLes fichiers partiels et le journal sont disponibles dans :`r`n$script:CurrentExportRoot"
    }

    Show-ErrorMessage -Message $ErrorMessage
    exit 1
}
finally {
    if ($null -ne $Configuration) {
        try {
            $Configuration.ApiKey = $null
            $Configuration.BasicPassword = $null
        }
        catch {
            # Aucun traitement complémentaire requis.
        }
    }

    [GC]::Collect()
}
