#Requires -Version 5.1
# Freshservice KB Export v3.4.2: automatic Analytics inventory and SecureString-protected preferences

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
# Graphical user interface
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

        [string]$Title = "Freshservice export error"
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

# User preferences without plaintext secrets.
# Sensitive values are protected by ConvertFrom-SecureString (Windows DPAPI, current user).
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

    # Windows PowerShell: ConvertFrom-SecureString without -Key uses DPAPI
    # under the current Windows account without an external .NET assembly.
    $SecureValue = $null
    try {
        $SecureValue = ConvertTo-SecureString -String $Value -AsPlainText -Force -ErrorAction Stop
        $EncryptedValue = ConvertFrom-SecureString -SecureString $SecureValue -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($EncryptedValue)) {
            throw 'Windows protection returned an empty value.'
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

    # Only the settings format created by this version is supported. Older attempts
    # that failed are not treated as valid secrets.
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
        return '' # Different Windows profile, corrupted value, or unavailable value.
    }
    finally {
        if ($Bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
        }
        if ($null -ne $SecureValue) { $SecureValue.Dispose() }
    }
}

function Read-FreshserviceSettings {
    # Reading settings must never create a folder: important on managed devices.
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
            catch { $Warnings.Add('Analytics URL could not be saved: ' + $_.Exception.Message) }
        }
        if ($Configuration.RememberApiKey) {
            try { $SaveApiKey = Protect-SettingString -Value $Configuration.ApiKey }
            catch { $Warnings.Add('API key could not be saved: ' + $_.Exception.Message) }
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
    # Non-sensitive preferences are saved even when DPAPI is unavailable.
    return $Warnings.ToArray()
}

function Clear-FreshserviceSettings {
    # Disabling saved preferences also clears any previous settings.
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
    # Never send the API key to a URL outside the configured tenant.
    return ($UriObject.Host -ieq $ExpectedDomain)
}

# Modern Windows Explorer folder-selection dialog.
# Windows PowerShell 5.1 otherwise defaults to the legacy FolderBrowserDialog.
# IFileDialog + FOS_PICKFOLDERS opens the modern Windows 10/11 picker.
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
                dialog.SetOkButtonLabel("Select this folder");
                if (!String.IsNullOrEmpty(initialFolder) &&
                    System.IO.Directory.Exists(initialFolder)) {
                    try {
                        Guid riid = typeof(IShellItem).GUID;
                        SHCreateItemFromParsingName(initialFolder, IntPtr.Zero, ref riid, out initialItem);
                        if (initialItem != null) dialog.SetFolder(initialItem);
                    } catch (COMException) { /* Let the dialog choose its own initial folder. */ }
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
    $Form.Text = 'Freshservice - Knowledge Base Export v3.4.2'
    $Form.Size = New-Object System.Drawing.Size(790, 680)
    $Form.StartPosition = 'CenterScreen'
    $Form.FormBorderStyle = 'FixedDialog'
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.ShowIcon = $false
    $Form.TopMost = $true

    $Title = New-Object System.Windows.Forms.Label
    $Title.Text = 'Freshservice Knowledge Base Export'
    $Title.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $Title.Location = New-Object System.Drawing.Point(22, 18)
    $Title.Size = New-Object System.Drawing.Size(730, 30)
    $Form.Controls.Add($Title)

    $Intro = New-Object System.Windows.Forms.Label
    $Intro.Text = "Export articles via API. Select a reporting file or use a scheduled Analytics export."
    $Intro.Location = New-Object System.Drawing.Point(24, 57)
    $Intro.Size = New-Object System.Drawing.Size(710, 32)
    $Form.Controls.Add($Intro)

    $DomainLabel = New-Object System.Windows.Forms.Label
    $DomainLabel.Text = 'Freshservice domain:'
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
    $ApiKeyLabel.Text = 'Freshservice API key:'
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
    $PasswordLabel.Text = 'Basic Auth (placeholder):'
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
    $AutoRadio.Text = 'Automatic - Analytics inventory (recommended)'
    $AutoRadio.Location = New-Object System.Drawing.Point(235, 225)
    $AutoRadio.Size = New-Object System.Drawing.Size(500, 26)
    $Form.Controls.Add($AutoRadio)

    $ManualRadio = New-Object System.Windows.Forms.RadioButton
    $ManualRadio.Text = 'Manual - select a CSV or XLSX file'
    $ManualRadio.Location = New-Object System.Drawing.Point(235, 252)
    $ManualRadio.Size = New-Object System.Drawing.Size(500, 26)
    $Form.Controls.Add($ManualRadio)

    # Automatic mode is restored only when its saved URL can be decrypted.
    # Never select automatic mode by default
    # unless a previously saved export URL can be decrypted.
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
    $UrlLabel.Text = "Analytics export URL:"
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
    $Info.Text = 'Scheduled Solutions Data Export URL: Analytics > Settings > Data Export. The article ID list is retrieved automatically.'
    $Info.Location = New-Object System.Drawing.Point(235, 327)
    $Info.Size = New-Object System.Drawing.Size(510, 40)
    $Info.ForeColor = [System.Drawing.Color]::DimGray
    $Form.Controls.Add($Info)

    $SourceFileLabel = New-Object System.Windows.Forms.Label
    $SourceFileLabel.Text = 'Reporting CSV or XLSX:'
    $SourceFileLabel.Location = New-Object System.Drawing.Point(24, 372)
    $SourceFileLabel.Size = New-Object System.Drawing.Size(205, 24)
    $Form.Controls.Add($SourceFileLabel)

    $SourceFileTextBox = New-Object System.Windows.Forms.TextBox
    $SourceFileTextBox.Location = New-Object System.Drawing.Point(235, 369)
    $SourceFileTextBox.Size = New-Object System.Drawing.Size(392, 26)
    $SourceFileTextBox.ReadOnly = $true
    $Form.Controls.Add($SourceFileTextBox)

    $BrowseSourceButton = New-Object System.Windows.Forms.Button
    $BrowseSourceButton.Text = 'Browse...'
    $BrowseSourceButton.Location = New-Object System.Drawing.Point(637, 367)
    $BrowseSourceButton.Size = New-Object System.Drawing.Size(98, 30)
    $Form.Controls.Add($BrowseSourceButton)
    $BrowseSourceButton.Add_Click({
        $FileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $FileDialog.Title = 'Select Freshservice reporting file (CSV or XLSX)'
        $FileDialog.Filter = 'CSV or Excel files (*.csv;*.xlsx)|*.csv;*.xlsx'
        $FileDialog.CheckFileExists = $true
        $FileDialog.AutoUpgradeEnabled = $true
        if ($FileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $SourceFileTextBox.Text = $FileDialog.FileName
        }
        $FileDialog.Dispose()
    })

    $ExportPathLabel = New-Object System.Windows.Forms.Label
    $ExportPathLabel.Text = "Export destination:"
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
    $BrowseExportButton.Text = 'Browse...'
    $BrowseExportButton.Location = New-Object System.Drawing.Point(637, 416)
    $BrowseExportButton.Size = New-Object System.Drawing.Size(98, 30)
    $Form.Controls.Add($BrowseExportButton)
    $BrowseExportButton.Add_Click({
        try {
            $SelectedFolder = Select-ModernExportFolder -Title 'Select Freshservice KB export destination' `
                -InitialFolder $ExportPathTextBox.Text -Owner $Form
            if (-not [string]::IsNullOrWhiteSpace($SelectedFolder)) {
                $ExportPathTextBox.Text = $SelectedFolder
            }
        }
        catch {
            Show-WarningMessage -Title 'Folder selection unavailable' `
                -Message ("Unable to open the Windows folder picker.`r`n" + $_.Exception.Message)
        }
    })

    $OpenFolderCheckBox = New-Object System.Windows.Forms.CheckBox
    $OpenFolderCheckBox.Text = "Open export folder when finished"
    $OpenFolderCheckBox.Location = New-Object System.Drawing.Point(235, 460)
    $OpenFolderCheckBox.Size = New-Object System.Drawing.Size(340, 24)
    $OpenFolderCheckBox.Checked = $true
    if ($null -ne $Settings -and $null -ne $Settings.OpenFolder) {
        $OpenFolderCheckBox.Checked = [bool]$Settings.OpenFolder
    }
    $Form.Controls.Add($OpenFolderCheckBox)

    $RememberCheckBox = New-Object System.Windows.Forms.CheckBox
    $RememberCheckBox.Text = "Remember preferences and optional URL (Windows protection)"
    $RememberCheckBox.Location = New-Object System.Drawing.Point(235, 490)
    $RememberCheckBox.Size = New-Object System.Drawing.Size(500, 24)
    $RememberCheckBox.Checked = $true
    if ($null -ne $Settings -and $null -ne $Settings.RememberConfiguration) {
        $RememberCheckBox.Checked = [bool]$Settings.RememberConfiguration
    }
    $Form.Controls.Add($RememberCheckBox)

    $RememberKeyCheckBox = New-Object System.Windows.Forms.CheckBox
    $RememberKeyCheckBox.Text = 'Also remember the API key on this computer (Windows protection)'
    $RememberKeyCheckBox.Location = New-Object System.Drawing.Point(235, 518)
    $RememberKeyCheckBox.Size = New-Object System.Drawing.Size(500, 24)
    $RememberKeyCheckBox.Checked = $false
    if ($null -ne $Settings -and $null -ne $Settings.RememberApiKey) {
        $RememberKeyCheckBox.Checked = [bool]$Settings.RememberApiKey
    }
    $Form.Controls.Add($RememberKeyCheckBox)

    # Display only the fields required by the selected mode.
    # Manual mode never requires an Analytics URL.
    $RefreshSourceControls = {
        $IsAuto = $AutoRadio.Checked
        $UrlLabel.Visible = $IsAuto
        $UrlTextBox.Visible = $IsAuto
        $SourceFileLabel.Visible = -not $IsAuto
        $SourceFileTextBox.Visible = -not $IsAuto
        $BrowseSourceButton.Visible = -not $IsAuto
        if ($IsAuto) {
            $Info.Text = "Paste the API URL of your scheduled Freshservice Solutions Data Export."
        }
        else {
            $Info.Text = "Select a Knowledge Base reporting file in CSV or XLSX format. No Analytics URL is required."
        }
    }
    $AutoRadio.Add_CheckedChanged($RefreshSourceControls)
    $ManualRadio.Add_CheckedChanged($RefreshSourceControls)
    & $RefreshSourceControls

    $StartButton = New-Object System.Windows.Forms.Button
    $StartButton.Text = "Start export"
    $StartButton.Location = New-Object System.Drawing.Point(480, 570)
    $StartButton.Size = New-Object System.Drawing.Size(145, 36)
    $StartButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $Form.Controls.Add($StartButton)

    $CancelButton = New-Object System.Windows.Forms.Button
    $CancelButton.Text = 'Cancel'
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
        if (-not $DomainRaw) { $Missing.Add('Freshservice domain') }
        if (-not $ApiKey) { $Missing.Add('Freshservice API key') }
        if (-not $BasicPassword) { $Missing.Add('Basic Auth') }
        if ($SourceMode -eq 'Automatic' -and -not $AutoUrl) { $Missing.Add("Analytics export URL (automatic mode only)") }
        if ($SourceMode -eq 'Manual' -and -not $SourceFile) { $Missing.Add('Reporting CSV or XLSX file') }
        if (-not $ExportPath) { $Missing.Add("Export destination") }

        if ($Missing.Count -gt 0) {
            $MissingText = ($Missing.ToArray() | ForEach-Object { '- ' + $_ }) -join "`r`n"
            Show-WarningMessage -Title 'Missing required fields' -Message "All required fields must be completed.`r`n`r`n$MissingText"
            continue
        }

        $Domain = Normalize-FreshserviceDomain -Domain $DomainRaw
        if ($Domain -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
            Show-WarningMessage -Title 'Invalid domain' -Message 'Expected domain format: yourcompany.freshservice.com'
            continue
        }
        if ($SourceMode -eq 'Automatic') {
            if (-not (Test-AutomaticExportUrl -Url $AutoUrl -ExpectedDomain $Domain)) {
                Show-WarningMessage -Title 'Invalid Analytics URL' -Message "The URL must use HTTPS and belong to the configured Freshservice domain.`r`nUse the Data Exports API URL, not the reporting page URL."
                continue
            }
        }
        else {
            if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
                Show-WarningMessage -Title 'File not found' -Message "Reporting file could not be accessed:`r`n$SourceFile"
                continue
            }
            if ([IO.Path]::GetExtension($SourceFile).ToLowerInvariant() -notin @('.csv','.xlsx')) {
                Show-WarningMessage -Title 'Invalid file format' -Message 'A CSV or XLSX file is required.'
                continue
            }
        }
        if (-not (Test-Path -LiteralPath $ExportPath -PathType Container)) {
            Show-WarningMessage -Title 'Invalid destination folder' -Message "Destination folder not found:`r`n$ExportPath"
            continue
        }
        if ($ExportPath.Length -gt 120) {
            Show-WarningMessage -Title 'Path too long' -Message 'Choose a shorter export destination, for example inside your Windows user profile.'
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
    $Form.Text = 'Freshservice export in progress'
    $Form.Size = New-Object System.Drawing.Size(650, 185)
    $Form.StartPosition = 'CenterScreen'
    $Form.FormBorderStyle = 'FixedDialog'
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.ControlBox = $false
    $Form.ShowIcon = $false
    $Form.TopMost = $true

    $Label = New-Object System.Windows.Forms.Label
    $Label.Text = "Initializing export..."
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
# API functions
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
            throw "HTTP $StatusText error during GET request: $Uri`r`n$($_.Exception.Message)"
        }
    }

    throw "Maximum retry attempts reached for: $Uri"
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

        Update-ProgressWindow -ProgressWindow $ProgressWindow -Message "Reading page $Page...`r`n$BaseUri"

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
# Automatic inventory acquisition via Analytics Data Exports
# -----------------------------------------------------------------------------

function Assert-TrustedDownloadUri {
    param([Parameter(Mandatory)][string]$Url)
    $Parsed = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$Parsed) -or $Parsed.Scheme -ne 'https') {
        throw 'Invalid reporting download link: HTTPS is required.'
    }
    $HostName = $Parsed.Host.ToLowerInvariant()
    $Suffixes = @('freshservice.com','freshworks.com','amazonaws.com','cloudfront.net')
    foreach ($Suffix in $Suffixes) {
        if ($HostName -eq $Suffix -or $HostName.EndsWith('.' + $Suffix)) { return }
    }
    throw "Unrecognized download domain $HostName. No credentials will be sent to this domain."
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
            # Export URLs may contain access tokens: do not log the URL.
            $Detail = if ($Status) { "HTTP $Status" } else { $_.Exception.GetType().Name }
            throw "Unable to download Analytics inventory ($Detail). Check the Data Export configuration, access rights, and latest export time. Manual mode remains available."
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
    Update-ProgressWindow -ProgressWindow $ProgressWindow -Message "Downloading latest inventory from Analytics..."
    Invoke-InventoryWebDownload -Url $Configuration.AutomaticUrl -OutputFile $RawFile -Headers $Headers

    for ($Hop = 0; $Hop -lt 3; $Hop++) {
        $Data = [IO.File]::ReadAllBytes($RawFile)
        if ($Data.Length -eq 0) { throw "The Analytics API URL returned an empty file." }
        if ($Data.Length -gt 52428800) { throw 'Inventory exceeds 50 MB: manual review required.' }

        # Analytics may return a JSON object pointing to the CSV.
        $FirstText = [Text.Encoding]::UTF8.GetString($Data, 0, [Math]::Min(400, $Data.Length)).TrimStart([char[]]@([char]0xFEFF, [char]32, [char]13, [char]10, [char]9))
        if ($FirstText.StartsWith('{')) {
            $Payload = $null
            try { $Payload = [Text.Encoding]::UTF8.GetString($Data) | ConvertFrom-Json }
            catch { throw "The Analytics export response is not valid JSON." }
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
            if (-not $Link) { throw "The Analytics API returned neither a CSV/XLSX file nor a usable download URL." }
            Assert-TrustedDownloadUri -Url $Link
            $LinkUri = [Uri]$Link
            # Do not send authentication headers to a signed third-party URL.
            $FollowHeaders = @{}
            if ($LinkUri.Host -ieq $Configuration.Domain) { $FollowHeaders = $Headers }
            Invoke-InventoryWebDownload -Url $Link -OutputFile $RawFile -Headers $FollowHeaders
            continue
        }
        break
    }
    $Data = [IO.File]::ReadAllBytes($RawFile)
    if ($Data.Length -lt 1) { throw "The inventory download is empty." }
    $HeaderText = [Text.Encoding]::UTF8.GetString($Data, 0, [Math]::Min(250, $Data.Length)).TrimStart()
    if ($HeaderText.StartsWith('<')) {
        throw "The Analytics URL returned an HTML page (login or error) instead of a CSV or XLSX inventory."
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
            if ($Candidate.Count -eq 0) { throw 'The Analytics ZIP archive contains no CSV or XLSX file.' }
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
    if ($HeaderText.StartsWith('{')) { throw "The Analytics API URL did not return a file after download redirects." }
    # For automatic mode, Freshservice documents CSV exports.
    # Also check that the first line resembles an inventory table.
    $FirstLine = [Text.Encoding]::UTF8.GetString($Data, 0, [Math]::Min(2000, $Data.Length)) -split '\r?\n' | Select-Object -First 1
    $FirstLineClean = $FirstLine.TrimStart([char]0xFEFF)
    if ($FirstLineClean -notmatch '(?i)(^|[,;\t])\s*"?(id|article[ _]?id|solution[ _]?id)"?\s*([,;\t]|$)') {
        throw "The downloaded inventory has no recognized ID column. Verify that the Data Export includes Knowledge Base articles."
    }
    $Destination = Join-Path $ExportRoot 'report-source-auto.csv'
    Move-Item -LiteralPath $RawFile -Destination $Destination -Force
    return $Destination
}

# -----------------------------------------------------------------------------
# Reading the reporting file
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
        throw 'The source file contains no data rows.'
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
        throw "The article ID column is missing.`r`n`r`nA column named ID, Article ID, or Solution ID is required.`r`n`r`nDetected columns: $AvailableHeaders"
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
        throw 'The CSV file is empty.'
    }

    $Candidates = @(
        [PSCustomObject]@{ Character = ';'; Count = ([regex]::Matches($FirstLine, ';')).Count },
        [PSCustomObject]@{ Character = ','; Count = ([regex]::Matches($FirstLine, ',')).Count },
        [PSCustomObject]@{ Character = "`t"; Count = ([regex]::Matches($FirstLine, "`t")).Count }
    )

    $Selected = $Candidates | Sort-Object Count -Descending | Select-Object -First 1

    if ($Selected.Count -le 0) {
        throw "Unable to detect the CSV delimiter. Supported delimiters are semicolon, comma, and tab."
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
            throw "Unable to read the CSV file.`r`n$($_.Exception.Message)"
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
            # Explicit release is a security measure and does not interrupt the export.
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
            throw "Microsoft Excel is not available to read XLSX files. Save the report as CSV and restart the script, or run it on a computer with Excel installed."
        }

        $Excel.Visible = $false
        $Excel.DisplayAlerts = $false
        $Workbook = $Excel.Workbooks.Open($Path, 0, $true)
        $Worksheet = $Workbook.Worksheets.Item(1)
        $UsedRange = $Worksheet.UsedRange

        $RowCount = [int]$UsedRange.Rows.Count
        $ColumnCount = [int]$UsedRange.Columns.Count

        if ($RowCount -lt 2 -or $ColumnCount -lt 1) {
            throw "The first worksheet in the XLSX file does not contain a usable table."
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
                # No further processing is required.
            }
        }

        if ($null -ne $Excel) {
            try {
                $Excel.Quit()
            }
            catch {
                # No further processing is required.
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
            throw 'The source file must be CSV or XLSX.'
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
                    Error      = "Missing or invalid article ID in the source file."
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
# Category and folder reference data
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
# Output files
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
    $SafeName = $SafeName.Trim().TrimEnd([char[]]@(' ', '.'))

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
        $SafeName = $SafeName.Substring(0, $MaxLength).TrimEnd([char[]]@(' ', '.'))
    }

    if ([string]::IsNullOrWhiteSpace($SafeName)) {
        $SafeName = 'Unnamed'
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
            $DescriptionHtml = '<p><a href="{0}" target="_blank">Open external resource</a></p>' -f $EncodedUrl
        }
        else {
            $DescriptionHtml = "<p>The API returned no article text.</p>"
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
<html lang="en">
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
        <p><strong>Freshservice link:</strong> <a href="$FreshserviceLinkEncoded" target="_blank">Open article</a></p>
        <p><strong>Category:</strong> $CategoryEncoded</p>
        <p><strong>Folder:</strong> $FolderEncoded</p>
        <p><strong>Folder path:</strong> $FolderPathEncoded</p>
        <p><strong>Type (report):</strong> $SourceTypeEncoded</p>
        <p><strong>Status (report):</strong> $SourceStatusEncoded</p>
        <p><strong>Author (report):</strong> $SourceAuthorEncoded</p>
        <p><strong>Workspace ID :</strong> $WorkspaceId</p>
        <p><strong>API status:</strong> $ApiStatus</p>
        <p><strong>API type:</strong> $ApiArticleType</p>
        <p><strong>Created:</strong> $CreatedAt</p>
        <p><strong>Updated:</strong> $UpdatedAt</p>
        <p><strong>Modified:</strong> $ModifiedAt</p>
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
                # No further processing is required.
            }
        }

        if ($null -ne $Excel) {
            try {
                $Excel.Quit()
            }
            catch {
                # No further processing is required.
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
# Main export
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
    Add-ExportLog -LogPath $LogPath -Message "Export started from $ApiBase"
    if ($Configuration.SourceMode -eq 'Automatic') {
        # Never log the Analytics URL: it may contain an access token.
        Add-ExportLog -LogPath $LogPath -Message 'Source: latest Analytics Data Export via API URL.'
        $Configuration.SourceFile = Get-AutomaticReportSource -Configuration $Configuration -Headers $Headers `
            -ExportRoot $ExportRoot -ProgressWindow $ProgressWindow
    }
    else {
        Add-ExportLog -LogPath $LogPath -Message "Source: local reporting file $($Configuration.SourceFile)"
    }

    $ExportErrors = New-Object 'System.Collections.Generic.List[object]'
    $ArticleResults = New-Object 'System.Collections.Generic.List[object]'
    $CompleteArticles = New-Object 'System.Collections.Generic.List[object]'

    Update-ProgressWindow -ProgressWindow $ProgressWindow -Message 'Reading reporting file...'
    $SourceRows = @(Read-SourceRows -Path $Configuration.SourceFile)

    if ($SourceRows.Count -eq 0) {
        throw 'The reporting file contains no data rows.'
    }

    $HeaderMap = Get-HeaderMap -Rows $SourceRows
    $SourceArticles = @(Get-DeduplicatedSourceArticles -Rows $SourceRows -HeaderMap $HeaderMap -Errors $ExportErrors)

    if ($SourceArticles.Count -eq 0) {
        throw "No valid article IDs were found in the reporting file."
    }

    Add-ExportLog -LogPath $LogPath -Message "Source rows: $($SourceRows.Count). Unique articles after deduplication: $($SourceArticles.Count)."

    $SourceCleanCsvPath = Join-Path -Path $ExportRoot -ChildPath 'source-deduplicated.csv'
    $SourceArticles | Export-Csv -LiteralPath $SourceCleanCsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8

    Update-ProgressWindow -ProgressWindow $ProgressWindow -Message 'Retrieving Freshservice categories...'
    $Categories = @(
        Get-FreshservicePagedCollection `
            -BaseUri "$ApiBase/categories" `
            -CollectionProperty 'categories' `
            -Headers $Headers `
            -PerPage $PerPage `
            -ProgressWindow $ProgressWindow
    )

    Update-ProgressWindow -ProgressWindow $ProgressWindow -Message 'Retrieving all Freshservice folders...'
    $Folders = @(
        Get-FreshservicePagedCollection `
            -BaseUri "$ApiBase/folders" `
            -CollectionProperty 'folders' `
            -Headers $Headers `
            -PerPage $PerPage `
            -ProgressWindow $ProgressWindow
    )

    Add-ExportLog -LogPath $LogPath -Message "Categories retrieved: $($Categories.Count). Folders retrieved: $($Folders.Count)."

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
            -Message "Article $ArticleNumber/$($SourceArticles.Count)`r`nID : $ArticleId - $($SourceArticle.Title)"

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

            Add-ExportLog -LogPath $LogPath -Level 'ERROR' -Message "Failed to retrieve article ${ArticleId}: $ErrorMessage"

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
                    FileResult        = 'NotAttempted'
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

        $FileWriteError = $null
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
            $FileWriteError = $FileError
            $ExportErrors.Add(
                [PSCustomObject]@{
                    Level      = 'ArticleFile'
                    SourceRow  = $null
                    ArticleId  = $ArticleId
                    Error      = $FileError
                }
            )

            Add-ExportLog -LogPath $LogPath -Level 'ERROR' -Message "Failed to write files for article ${ArticleId}: $FileError"
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

        $FileResult = if ($null -eq $FileWriteError) { 'Success' } else { 'Error' }

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
                FileResult        = $FileResult
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
                Error             = $FileWriteError
            }
        )

        Start-Sleep -Milliseconds 80
    }

    Update-ProgressWindow -ProgressWindow $ProgressWindow -Message 'Creating consolidated inventories...'

    $CleanCsvPath = Join-Path -Path $ExportRoot -ChildPath 'articles-clean.csv'
    $CleanXlsxPath = Join-Path -Path $ExportRoot -ChildPath 'articles-clean.xlsx'
    $CompleteJsonPath = Join-Path -Path $ExportRoot -ChildPath 'articles-complete.json'
    $ErrorsPath = Join-Path -Path $ExportRoot -ChildPath 'export-errors.csv'

    $ArticleResults.ToArray() | Export-Csv -LiteralPath $CleanCsvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Write-JsonFile -Data $CompleteArticles.ToArray() -Path $CompleteJsonPath

    $XlsxCreated = Export-ObjectsToXlsx -Rows $ArticleResults.ToArray() -Path $CleanXlsxPath -WorksheetName 'Articles clean'
    if (-not $XlsxCreated) {
        Add-ExportLog -LogPath $LogPath -Level 'WARNING' -Message "articles-clean.xlsx was not created because Microsoft Excel was unavailable. The CSV inventory is available."
    }

    if ($ExportErrors.Count -gt 0) {
        $ExportErrors.ToArray() | Export-Csv -LiteralPath $ErrorsPath -Delimiter ';' -NoTypeInformation -Encoding UTF8
    }

    $SuccessCount = @($ArticleResults | Where-Object { $_.ApiResult -eq 'Success' }).Count
    $FailureCount = @($ArticleResults | Where-Object { $_.ApiResult -eq 'Error' }).Count
    $FileSuccessCount = @($ArticleResults | Where-Object { $_.FileResult -eq 'Success' }).Count
    $FileFailureCount = @($ArticleResults | Where-Object { $_.FileResult -eq 'Error' }).Count

    Add-ExportLog -LogPath $LogPath -Message "Export completed. Source rows: $($SourceRows.Count), unique IDs: $($SourceArticles.Count), successful API calls: $SuccessCount, failed API calls: $FailureCount, saved article pairs (HTML + JSON): $FileSuccessCount, failed article file writes: $FileFailureCount, total errors: $($ExportErrors.Count)."

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
        FileSuccessCount = $FileSuccessCount
        FileFailureCount = $FileFailureCount
        ErrorCount       = $ExportErrors.Count
        XlsxCreated      = $XlsxCreated
    }
}

# -----------------------------------------------------------------------------
# Execution
# -----------------------------------------------------------------------------

$Configuration = $null
$ProgressWindow = $null

try {
    $Configuration = Get-ExportConfiguration

    if ($null -eq $Configuration) {
        exit 0
    }

    # Saving preferences is optional. Never attempt it if the checkbox is cleared.
    # Failed storage or encryption must never block article extraction.
    if ($Configuration.RememberConfiguration) {
        try {
            $SaveWarnings = @(Save-FreshserviceSettings -Configuration $Configuration)
            if ($SaveWarnings.Count -gt 0) {
                Show-WarningMessage -Title 'Some preferences were not saved' -Message ((@($SaveWarnings) -join "`r`n") + "`r`n`r`nThe export can continue without saving these preferences.")
            }
        }
        catch {
            Show-WarningMessage -Title 'Preferences not saved' -Message ("Unable to save preferences:`r`n" + $_.Exception.Message + "`r`n`r`nThe export can continue.")
        }
    }
    else {
        try { Clear-FreshserviceSettings }
        catch {
            Show-WarningMessage -Title 'Previous preferences not removed' -Message ("Unable to remove previous preferences:`r`n" + $_.Exception.Message + "`r`n`r`nThe export can continue.")
        }
    }

    $ProgressWindow = New-ProgressWindow
    $Result = Export-FreshserviceKnowledgeBaseFromReport `
        -Configuration $Configuration `
        -ProgressWindow $ProgressWindow

    Close-ProgressWindow -ProgressWindow $ProgressWindow
    $ProgressWindow = $null

    $XlsxMessage = if ($Result.XlsxCreated) {
        'The CSV and XLSX inventories were generated.'
    }
    else {
        "The CSV inventory was generated. The XLSX file could not be created because Microsoft Excel was unavailable."
    }

    if ($Result.FailureCount -eq 0 -and $Result.ErrorCount -eq 0) {
        $Message = @"
Export completed successfully.

Reporting rows: $($Result.SourceRowCount)
Unique IDs: $($Result.UniqueIdCount)
Categories: $($Result.CategoryCount)
Folders: $($Result.FolderCount)
Successful API reads: $($Result.SuccessCount)
Articles saved (HTML + JSON): $($Result.FileSuccessCount)

$XlsxMessage

Folder:
$($Result.ExportRoot)
"@

        Show-InformationMessage -Message $Message -Title 'Freshservice export completed'
    }
    else {
        $Message = @"
Export completed with warnings.

Reporting rows: $($Result.SourceRowCount)
Unique IDs: $($Result.UniqueIdCount)
Categories: $($Result.CategoryCount)
Folders: $($Result.FolderCount)
Successful API reads: $($Result.SuccessCount)
Failed API reads: $($Result.FailureCount)
Articles saved (HTML + JSON): $($Result.FileSuccessCount)
Failed article file writes: $($Result.FileFailureCount)
Logged errors: $($Result.ErrorCount)

$XlsxMessage

Folder:
$($Result.ExportRoot)

Details are available in export-errors.csv and export.log.
"@

        Show-WarningMessage -Message $Message -Title 'Freshservice export completed with warnings'
    }

    if ($Configuration.OpenFolder -and (Test-Path -LiteralPath $Result.ExportRoot -PathType Container)) {
        Start-Process -FilePath $Result.ExportRoot
    }
}
catch {
    Close-ProgressWindow -ProgressWindow $ProgressWindow
    $ProgressWindow = $null

    $ErrorMessage = "The export failed.`r`n`r`n$($_.Exception.Message)"

    if (
        -not [string]::IsNullOrWhiteSpace([string]$script:CurrentExportRoot) -and
        (Test-Path -LiteralPath $script:CurrentExportRoot -PathType Container)
    ) {
        $ErrorMessage += "`r`n`r`nPartial files and execution logs are available in:`r`n$script:CurrentExportRoot"
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
            # No further processing is required.
        }
    }

    [GC]::Collect()
}
