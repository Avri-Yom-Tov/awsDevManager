#
# AWS Credential Manager GUI
# Combines AWS credential management with a modern Windows 11 style GUI
#

#CREATE HASHTABLE AND RUNSPACE FOR GUI
$WPFGui = [hashtable]::Synchronized(@{ })
$newRunspace = [runspacefactory]::CreateRunspace()
$newRunspace.ApartmentState = "STA"
$newRunspace.ThreadOptions = "UseNewThread"
$newRunspace.Open()
$newRunspace.SessionStateProxy.SetVariable("WPFGui", $WPFGui)

#Create master runspace and add code
$psCmd = [System.Management.Automation.PowerShell]::Create().AddScript( {

    # Add WPF and Windows Forms assemblies
    try {
        Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Drawing, system.windows.forms, System.Windows.Controls.Ribbon, System.DirectoryServices.AccountManagement
    }
    catch {
        Throw 'Failed to load Windows Presentation Framework assemblies.'
    }

    try {
        Add-Type -Name Win32Util -Namespace System -MemberDefinition @'
[DllImport("Kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("User32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);

[DllImport("user32.dll", SetLastError = true)] 
public static extern int GetWindowLong(IntPtr hWnd, int nIndex); 

[DllImport("user32.dll")] 
public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

[DllImport("user32.dll")]
public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

[DllImport("user32.dll")]
public static extern bool BringWindowToTop(IntPtr hWnd);

[DllImport("user32.dll")]
public static extern bool SwitchToThisWindow(IntPtr hWnd, bool fUnknown);

const UInt32 SWP_NOSIZE = 0x0001;
const UInt32 SWP_NOMOVE = 0x0002;
const UInt32 SWP_NOACTIVATE = 0x0010;
const UInt32 SWP_SHOWWINDOW = 0x0040;

static readonly IntPtr HWND_BOTTOM = new IntPtr(1);
static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
static readonly IntPtr HWND_TOP = new IntPtr(0);
static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

public static void SetBottom(IntPtr hWindow)
{
    SetWindowPos(hWindow, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

public static void SetTop(IntPtr hWindow)
{
    SetWindowPos(hWindow, HWND_TOP, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
}
'@
    }
    catch {
        Write-Verbose "Win32Util already defined"
    }

    #region Utility Functions

    # This is the list of functions to add to the InitialSessionState that is used for all Asynchronus Runsspaces
    $SessionFunctions = New-Object  System.Collections.ArrayList

    function Invoke-Async {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [ScriptBlock]
            $Code,
            [Parameter(Mandatory = $false)]
            [hashtable]
            $Variables
        )
        # Add the above code to a runspace and execute it.
        $PSinstance = [powershell]::Create()
        $PSinstance.Runspace = [runspacefactory]::CreateRunspace($InitialSessionState)
        $PSinstance.Runspace.ApartmentState = "STA"
        $PSinstance.Runspace.ThreadOptions = "ReuseThread"
        $PSinstance.Runspace.Open()
        if ($Variables) {
            # Pass in the specified variables from $VariableList
            $Variables.keys.ForEach({ 
                    $PSInstance.Runspace.SessionStateProxy.SetVariable($_, $Variables.$_)
                })
        }
        $PSInstance.AddScript($Code)
        $PSinstance.BeginInvoke()
        $WPFGui.Error = $PSInstance.Streams.Error
    }
    $SessionFunctions.Add('Invoke-Async') | Out-Null

    Function New-WPFDialog() {
        Param(
            [Parameter(Mandatory = $True, HelpMessage = 'XaML Data defining a WPF <window>', Position = 1)]
            [string]$XamlData,
            [Parameter(Mandatory = $False, HelpMessage = 'XaML Data defining WPF <Window.Resources', Position = 2)]
            [string]$Resources
        )
        # Create an XML Object with the XaML data in it
        [xml]$xmlWPF = $XamlData

        #If a Resource Dictionary has been included, import and append it to our Window
        if ( -not [System.String]::IsNullOrEmpty( $Resources )) {
            [xml]$xmlResourceWPF = $Resources
            Foreach ($ChildNode in $xmlResourceWPF.ResourceDictionary.ChildNodes) {
        ($ImportNode = $xmlWPF.ImportNode($ChildNode, $true)) | Out-Null
                $xmlWPF.Window.'Window.Resources'.AppendChild($ImportNode) | Out-Null
            }
        }

        # Create the XAML reader using a new XML node reader, UI is the only hard-coded object name here
        $XaMLReader = New-Object System.Collections.Hashtable
        $XaMLReader.Add('UI', ([Windows.Markup.XamlReader]::Load((new-object -TypeName System.Xml.XmlNodeReader -ArgumentList $xmlWPF)))) | Out-Null

        # Create hooks to each named object in the XAML reader
        $Elements = $xmlWPF.SelectNodes('//*[@Name]')
        ForEach ( $Element in $Elements ) {
            $VarName = $Element.Name
            $VarValue = $XaMLReader.UI.FindName($Element.Name)
            $XaMLReader.Add($VarName, $VarValue) | Out-Null
        }
        return $XaMLReader
    }
    $SessionFunctions.Add('New-WPFDialog') | Out-Null

    Function New-MessageDialog() {
        Param(
            [Parameter(Mandatory = $True, HelpMessage = 'Dialog Title', Position = 1)]
            [string]$DialogTitle,

            [Parameter(Mandatory = $True, HelpMessage = 'Major Header', Position = 2)]
            [string]$H1,

            [Parameter(Mandatory = $True, HelpMessage = 'Message Text', Position = 3)]
            [string]$DialogText,

            [Parameter(Mandatory = $false, HelpMessage = 'Cancel Text', Position = 4)]
            [string]$CancelText = $null,

            [Parameter(Mandatory = $True, HelpMessage = 'Confirm Text', Position = 5)]
            [string]$ConfirmText,

            [Parameter(Mandatory = $false, HelpMessage = 'Plays sound if set', Position = 6)]
            [switch]$Beep,

            [Parameter(Mandatory = $false, HelpMessage = 'Shows input TextBox if set', Position = 7)]
            [switch]$GetInput,

            [Parameter(Mandatory = $false, HelpMessage = 'Shows error icon if set', Position = 8)]
            [switch]$IsError,

            [Parameter(Mandatory = $false, HelpMessage = 'Process asynchronously when set', Position = 9)]
            [switch]$IsAsync,

            [Parameter(Mandatory = $true, HelpMessage = 'Owner Window, required when this is a child', Position = 10)]
            [PSObject]$Owner
        )

        $Dialog = New-WPFDialog -XamlData @'
<Window x:Class="System.Windows.Window"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Name="MainWindow"
        Title="__DIALOGTITLE__"
        ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner"
        SizeToContent="WidthAndHeight"
        Width="420"
        MinWidth="420"
        MaxWidth="700"
        Height="212"
        MinHeight="212"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Padding="20"
        ShowInTaskbar="False">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" ResizeBorderThickness="2" CornerRadius="8" />
    </WindowChrome.WindowChrome>
    <Border BorderThickness="1" BorderBrush="#FF005FB8" Background="White" CornerRadius="8" Margin="10">
        <Border.Effect>
            <DropShadowEffect BlurRadius="10" ShadowDepth="5" Color="#FF959595" Opacity="0.7" />
        </Border.Effect>
        <Grid>
            <TextBlock Name="DialogTitle" Text="__DIALOGTITLE__" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="8,6,0,0" />
            <DockPanel Margin="22,48,24,24">
                <TextBlock DockPanel.Dock="Top" Name="H1" Text="__H1__" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="0" FontSize="27" />
                <TextBlock DockPanel.Dock="Top" Name="DialogText" Text="__DIALOGTEXT__" TextWrapping="Wrap" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="0,8,0,0" FontSize="15" />
                <TextBox DockPanel.Dock="Top" Name="Input" Visibility="Hidden" Margin="0,10" FontSize="15" />
                <StackPanel DockPanel.Dock="Bottom" Margin="0" HorizontalAlignment="Right" VerticalAlignment="Bottom" Orientation="Horizontal">
                    <Button Name="CancelButton" Content="__CANCELTEXT__" HorizontalAlignment="Right" Margin="0,0,24,0" VerticalAlignment="Bottom" FontSize="15" />
                    <Button Name="ConfirmButton" Content="__CONFIRMTEXT__" HorizontalAlignment="Right" Margin="0" VerticalAlignment="Bottom" IsDefault="True" FontSize="15" />
                </StackPanel>
            </DockPanel>
        </Grid>
    </Border>
</Window>
'@

        if ($Owner) {
            $Dialog.UI.Owner = $Owner
        }

        $Dialog.MainWindow.Title = $DialogTitle
        $Dialog.DialogTitle.Text = $DialogTitle
        $Dialog.H1.Text = $H1
        $Dialog.DialogText.Text = $DialogText
        if ($CancelText) {
            $Dialog.CancelButton.Content = $CancelText
        }
        else {
            $Dialog.CancelButton.Visibility = 'hidden'
        }
        $Dialog.ConfirmButton.Content = $ConfirmText

        if ($GetInput) {
            $Dialog.Input.Visibility = 'Visible'
        }

        $Dialog.Add('Result', [System.Windows.Forms.DialogResult]::Cancel) | Out-Null

        $Dialog.ConfirmButton.add_Click( {
                $Dialog.Result = [System.Windows.Forms.DialogResult]::OK
                $Dialog.UI.Close()
            })
        $Dialog.CancelButton.Add_Click( {
                $Dialog.Result = [System.Windows.Forms.DialogResult]::Cancel
                $Dialog.UI.Close()
            })
        $Dialog.UI.add_ContentRendered( {
                if ($Beep) {
                    [system.media.systemsounds]::Exclamation.play()
                }
            })

        $null = $Dialog.UI.Dispatcher.InvokeAsync{ $Dialog.UI.ShowDialog() }.Wait()

        return @{
            DialogResult = $Dialog.Result
            Text         = $Dialog.Input.Text
        }
    }
    $SessionFunctions.Add('New-MessageDialog') | Out-Null

    function Write-Activity {
        param (
            [Parameter(Mandatory = $true)]
            [string]
            $Prefix,
            [Parameter(Mandatory = $true)]
            [string]
            $Text,
            [Parameter(Mandatory = $true)]
            [string]
            $Stream,
            [switch]
            $IsError
        )
        $WPFGui.UI.Dispatcher.Invoke([action] {
                $DateStamp = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
                $TextRun = New-Object System.Windows.Documents.Run
                $TextRun.Foreground = "Red"
                $TextRun.Text = $DateStamp
                $Paragraph = New-Object System.Windows.Documents.Paragraph($TextRun)

                $TextRun = New-Object System.Windows.Documents.Run
                $TextRun.Foreground = "#FF9A9A9A"
                $TextRun.Text = ":"
                $Paragraph.Inlines.Add($TextRun)

                $TextRun = New-Object System.Windows.Documents.Run
                $TextRun.Foreground = "#FF0078D7"
                $TextRun.Text = $Prefix
                $Paragraph.Inlines.Add($TextRun)

                $TextRun = New-Object System.Windows.Documents.Run
                $TextRun.Foreground = "#FF9A9A9A"
                $TextRun.Text = ": "
                $Paragraph.Inlines.Add($TextRun)

                $TextRun = New-Object System.Windows.Documents.Run
                if ( $IsError ) {
                    $TextRun.Foreground = "Red"
                }
                else {
                    $TextRun.Foreground = "Black"
                }

                $TextRun.Text = $Text
                $Paragraph.Inlines.Add($TextRun) | Out-Null
                $WPFGui."$Stream".Document.Blocks.Add($Paragraph)  | Out-Null
                $WPFGui."$Stream".ScrollToEnd()
            })
    }
    $SessionFunctions.Add('Write-Activity') | Out-Null

    function Write-StatusBar {
        param (
            [Parameter(Mandatory = $true)]
            [int]
            $Progress,
            [Parameter(Mandatory = $true)]
            [string]
            $Text
        )
        $WPFGui.UI.Dispatcher.invoke([action] {
                $WPFGui.Progress.Value = $Progress
                $WPFGui.StatusText.Text = $Text
            })
    }
    $SessionFunctions.Add('Write-StatusBar') | Out-Null

    function Start-AWSCredentialProcess {
        param(
            [string]$User,
            [string]$TargetProfile,
            [string]$TargetAccount,
            [string]$CodeArtifactProfile,
            [string]$CodeArtifactAccount,
            [string]$RoleName,
            [string]$SourceProfile,
            [string]$DefaultRegion
        )

        $MFA_SESSION = "$SourceProfile-mfa-session"
        $DEFAULT_SESSION = "default"
        $CODEARTIFACT_SESSION = "default-codeartifact"
        $main_iam_acct_num = '736763050260'
        $token_expiration_seconds = 129600 # 36 Hours

        # Get MFA token from user via popup (using UI dispatcher to ensure thread safety)
        $mfa_token = $null
        $WPFGui.UI.Dispatcher.Invoke([action]{
            $MfaDialog = New-MessageDialog -DialogTitle "MFA Required" -H1 "Enter MFA Code" -DialogText "Please enter your MFA token code:" -ConfirmText "OK" -CancelText "Cancel" -GetInput

            if ($MfaDialog.DialogResult -eq [System.Windows.Forms.DialogResult]::Cancel) {
                Write-Activity -Prefix 'AWS Manager' -Text 'MFA input cancelled by user' -Stream 'Output' -IsError
                return
            }

            $script:mfa_token = $MfaDialog.Text
        })
        
        if ([string]::IsNullOrWhiteSpace($mfa_token)) {
            Write-Activity -Prefix 'AWS Manager' -Text 'MFA token cannot be empty or was cancelled' -Stream 'Output' -IsError
            return $false
        }

        Write-Activity -Prefix 'AWS Manager' -Text 'Starting AWS credential renewal process...' -Stream 'Output'
        Write-StatusBar -Progress 10 -Text "Getting MFA session token..."

        # Piece together role information
        $mfa_device = "arn:aws:iam::" + $main_iam_acct_num + ":mfa/" + $User
        $target_role = "arn:aws:iam::" + $TargetAccount + ":role/" + $RoleName
        $target_role_codeartifact = "arn:aws:iam::" + $CodeArtifactAccount + ":role/" + $RoleName

        try {
            # Get session token with MFA
            $tokenResult = aws sts get-session-token --serial-number $mfa_device --duration-seconds $token_expiration_seconds --token-code $mfa_token --profile $SourceProfile 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                Write-Activity -Prefix 'AWS Manager' -Text "Failed to get MFA session token: $tokenResult" -Stream 'Output' -IsError
                return $false
            }

            $token_creds = $tokenResult | ConvertFrom-Json
            Write-Activity -Prefix 'AWS Manager' -Text 'Successfully obtained MFA session token' -Stream 'Output'
            Write-StatusBar -Progress 20 -Text "Setting up MFA session..."

            # Set AWS credentials for MFA session
            aws configure set aws_access_key_id $token_creds.Credentials.AccessKeyId --profile $MFA_SESSION
            aws configure set aws_secret_access_key $token_creds.Credentials.SecretAccessKey --profile $MFA_SESSION
            aws configure set aws_session_token $token_creds.Credentials.SessionToken --profile $MFA_SESSION
            aws configure set region $DefaultRegion --profile $TargetProfile
            aws configure set region $DefaultRegion --profile $CodeArtifactProfile

            Write-Activity -Prefix 'AWS Manager' -Text "Successfully cached MFA token for $token_expiration_seconds seconds" -Stream 'Output'

            # Start the renewal loop
            for ($hour = 36; $hour -gt 0 -and -not $WPFGui.ScriptShouldStop; $hour--) {
                
                Write-StatusBar -Progress (25 + (31 * (37 - $hour) / 36)) -Text "Renewing credentials... ($hour hours remaining)"
                Write-Activity -Prefix 'AWS Manager' -Text "Renewing $TargetProfile access keys... ($hour hours remaining)" -Stream 'Output'

                # Assume role for target account
                $credsResult = aws sts assume-role --role-arn $target_role --role-session-name $User --profile $MFA_SESSION --query "Credentials" 2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    $creds = $credsResult | ConvertFrom-Json
                    
                    # Add new lines to credentials files
                    $creds_file = "~/.aws/credentials"
                    if (-Not (Get-Content $creds_file -ErrorAction SilentlyContinue | Select-String $TargetProfile -quiet)) {
                        Add-Content -Path $creds_file -Value "`r`n" -ErrorAction SilentlyContinue
                    }

                    # Set AWS credentials
                    aws configure set aws_access_key_id $creds.AccessKeyId --profile $DEFAULT_SESSION
                    aws configure set aws_secret_access_key $creds.SecretAccessKey --profile $DEFAULT_SESSION
                    aws configure set aws_session_token $creds.SessionToken --profile $DEFAULT_SESSION
                    aws configure set region $DefaultRegion --profile $DEFAULT_SESSION

                    Write-Activity -Prefix 'AWS Manager' -Text "$TargetProfile profile has been updated in ~/.aws/credentials" -Stream 'Output'
                }

                # Renew CodeArtifact credentials
                Write-Activity -Prefix 'AWS Manager' -Text "Renewing $CodeArtifactProfile access keys..." -Stream 'Output'
                $credsCodeArtifactResult = aws sts assume-role --role-arn $target_role_codeartifact --role-session-name $User --profile $MFA_SESSION --query "Credentials" 2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    $creds_codeartifact = $credsCodeArtifactResult | ConvertFrom-Json
                    
                    # Add new lines to credentials files
                    if (-Not (Get-Content $creds_file -ErrorAction SilentlyContinue | Select-String $CodeArtifactProfile -quiet)) {
                        Add-Content -Path $creds_file -Value "`r`n" -ErrorAction SilentlyContinue
                    }

                    # Set CodeArtifact credentials
                    aws configure set aws_access_key_id $creds_codeartifact.AccessKeyId --profile $CODEARTIFACT_SESSION
                    aws configure set aws_secret_access_key $creds_codeartifact.SecretAccessKey --profile $CODEARTIFACT_SESSION
                    aws configure set aws_session_token $creds_codeartifact.SessionToken --profile $CODEARTIFACT_SESSION
                    aws configure set region $DefaultRegion --profile $CODEARTIFACT_SESSION

                    Write-Activity -Prefix 'AWS Manager' -Text "$CodeArtifactProfile profile has been updated in ~/.aws/credentials" -Stream 'Output'

                    # Get CodeArtifact authorization token
                    $CODEARTIFACT_AUTH_TOKEN = aws codeartifact get-authorization-token --domain nice-devops --domain-owner 369498121101 --query authorizationToken --output text --region us-west-2 --profile $CODEARTIFACT_SESSION 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Activity -Prefix 'AWS Manager' -Text 'Generated CodeArtifact token' -Stream 'Output'

                        # Update Maven settings.xml
                        try {
                            $file = "C:\Users\$env:UserName\.m2\settings.xml"
                            if (Test-Path $file) {
                                [xml]$x = Get-Content $file
                                $nodeId = $x.settings.servers.server | Where-Object { $_.id -eq "cxone-codeartifact" }
                                if ($nodeId) { $nodeId.password = $CODEARTIFACT_AUTH_TOKEN.ToString() }
                                $nodeId1 = $x.settings.servers.server | Where-Object { $_.id -eq "platform-utils" }
                                if ($nodeId1) { $nodeId1.password = $CODEARTIFACT_AUTH_TOKEN.ToString() }
                                $nodeId2 = $x.settings.servers.server | Where-Object { $_.id -eq "plugins-codeartifact" }
                                if ($nodeId2) { $nodeId2.password = $CODEARTIFACT_AUTH_TOKEN.ToString() }
                                $x.Save($file)
                                Write-Activity -Prefix 'AWS Manager' -Text "Updated $file with CodeArtifact token" -Stream 'Output'
                            }
                        } catch {
                            Write-Activity -Prefix 'AWS Manager' -Text "Could not update Maven settings.xml: $($_.Exception.Message)" -Stream 'Output'
                        }

                        # Update npm configuration
                        try {
                            npm config set registry "https://nice-devops-369498121101.d.codeartifact.us-west-2.amazonaws.com/npm/cxone-npm/" 2>$null | Out-Null
                            npm config set "//nice-devops-369498121101.d.codeartifact.us-west-2.amazonaws.com/npm/cxone-npm/:_authToken=$CODEARTIFACT_AUTH_TOKEN" 2>$null | Out-Null
                            Write-Activity -Prefix 'AWS Manager' -Text 'Updated npm configuration with CodeArtifact token' -Stream 'Output'
                        } catch {
                            Write-Activity -Prefix 'AWS Manager' -Text 'npm not installed or configuration failed' -Stream 'Output'
                        }
                    }
                }

                if ($hour -eq 1) {
                    Write-Activity -Prefix 'AWS Manager' -Text "Credentials will be renewed every 59 minutes for the next $hour hour" -Stream 'Output'
                } else {
                    Write-Activity -Prefix 'AWS Manager' -Text "Credentials will be renewed every 59 minutes for the next $hour hours" -Stream 'Output'
                }

                # Wait for 59 minutes or until stopped
                for ($i = 0; $i -lt 3540 -and -not $WPFGui.ScriptShouldStop; $i++) {
                    Start-Sleep -Seconds 1
                    if ($i % 60 -eq 0) {  # Update every minute
                        $minutesLeft = [math]::Floor((3540 - $i) / 60)
                        Write-StatusBar -Progress (25 + (31 * (37 - $hour) / 36)) -Text "Next renewal in $minutesLeft minutes... ($hour hours remaining)"
                    }
                }
            }

            if ($WPFGui.ScriptShouldStop) {
                Write-Activity -Prefix 'AWS Manager' -Text 'Credential renewal process stopped by user' -Stream 'Output'
            } else {
                Write-Activity -Prefix 'AWS Manager' -Text 'MFA token credentials have expired. Please restart the process.' -Stream 'Output'
            }

            Write-StatusBar -Progress 100 -Text "Process completed"
            return $true

        } catch {
            Write-Activity -Prefix 'AWS Manager' -Text "Error: $($_.Exception.Message)" -Stream 'Output' -IsError
            return $false
        }
    }
    $SessionFunctions.Add('Start-AWSCredentialProcess') | Out-Null

    function Start-AWSCredentialProcessWithToken {
        param(
            [string]$User,
            [string]$TargetProfile,
            [string]$TargetAccount,
            [string]$CodeArtifactProfile,
            [string]$CodeArtifactAccount,
            [string]$RoleName,
            [string]$SourceProfile,
            [string]$DefaultRegion,
            [string]$MfaToken
        )

        $MFA_SESSION = "$SourceProfile-mfa-session"
        $DEFAULT_SESSION = "default"
        $CODEARTIFACT_SESSION = "default-codeartifact"
        $main_iam_acct_num = '736763050260'
        $token_expiration_seconds = 129600 # 36 Hours

        Write-Activity -Prefix 'AWS Manager' -Text 'Starting AWS credential renewal process...' -Stream 'Output'
        Write-Activity -Prefix 'AWS Manager' -Text "Parameters - User: $User, Target: $TargetProfile, Account: $TargetAccount" -Stream 'Output'
        Write-StatusBar -Progress 10 -Text "Getting MFA session token..."

        # Piece together role information
        $mfa_device = "arn:aws:iam::" + $main_iam_acct_num + ":mfa/" + $User
        $target_role = "arn:aws:iam::" + $TargetAccount + ":role/" + $RoleName
        $target_role_codeartifact = "arn:aws:iam::" + $CodeArtifactAccount + ":role/" + $RoleName

        try {
            # Get session token with MFA
            Write-Activity -Prefix 'AWS Manager' -Text "Executing: aws sts get-session-token for device $mfa_device" -Stream 'Output'
            
            $tokenResult = $null
            $tokenError = $null
            
            # Execute AWS CLI command with timeout
            $job = Start-Job -ScriptBlock {
                param($mfa_device, $token_expiration_seconds, $MfaToken, $SourceProfile)
                try {
                    $result = aws sts get-session-token --serial-number $mfa_device --duration-seconds $token_expiration_seconds --token-code $MfaToken --profile $SourceProfile 2>&1
                    return @{
                        Success = ($LASTEXITCODE -eq 0)
                        Result = $result
                        ExitCode = $LASTEXITCODE
                    }
                } catch {
                    return @{
                        Success = $false
                        Result = $_.Exception.Message
                        ExitCode = -1
                    }
                }
            } -ArgumentList $mfa_device, $token_expiration_seconds, $MfaToken, $SourceProfile
            
            # Wait for job completion with timeout
            $jobResult = Wait-Job -Job $job -Timeout 30
            if ($jobResult) {
                $jobOutput = Receive-Job -Job $job
                Remove-Job -Job $job
                
                if ($jobOutput.Success) {
                    $tokenResult = $jobOutput.Result
                    Write-Activity -Prefix 'AWS Manager' -Text 'AWS CLI command completed successfully' -Stream 'Output'
                } else {
                    Write-Activity -Prefix 'AWS Manager' -Text "Failed to get MFA session token: $($jobOutput.Result)" -Stream 'Output' -IsError
                    return $false
                }
            } else {
                Remove-Job -Job $job -Force
                Write-Activity -Prefix 'AWS Manager' -Text "AWS CLI command timed out after 30 seconds" -Stream 'Output' -IsError
                return $false
            }

            $token_creds = $tokenResult | ConvertFrom-Json
            Write-Activity -Prefix 'AWS Manager' -Text 'Successfully obtained MFA session token' -Stream 'Output'
            Write-StatusBar -Progress 20 -Text "Setting up MFA session..."

            # Set AWS credentials for MFA session
            aws configure set aws_access_key_id $token_creds.Credentials.AccessKeyId --profile $MFA_SESSION
            aws configure set aws_secret_access_key $token_creds.Credentials.SecretAccessKey --profile $MFA_SESSION
            aws configure set aws_session_token $token_creds.Credentials.SessionToken --profile $MFA_SESSION
            aws configure set region $DefaultRegion --profile $TargetProfile
            aws configure set region $DefaultRegion --profile $CodeArtifactProfile

            Write-Activity -Prefix 'AWS Manager' -Text "Successfully cached MFA token for $token_expiration_seconds seconds" -Stream 'Output'

            # Start the renewal loop
            for ($hour = 36; $hour -gt 0 -and -not $WPFGui.ScriptShouldStop; $hour--) {
                
                Write-StatusBar -Progress (25 + (31 * (37 - $hour) / 36)) -Text "Renewing credentials... ($hour hours remaining)"
                Write-Activity -Prefix 'AWS Manager' -Text "Renewing $TargetProfile access keys... ($hour hours remaining)" -Stream 'Output'

                # Assume role for target account
                $credsResult = aws sts assume-role --role-arn $target_role --role-session-name $User --profile $MFA_SESSION --query "Credentials" 2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    $creds = $credsResult | ConvertFrom-Json
                    
                    # Add new lines to credentials files
                    $creds_file = "~/.aws/credentials"
                    if (-Not (Get-Content $creds_file -ErrorAction SilentlyContinue | Select-String $TargetProfile -quiet)) {
                        Add-Content -Path $creds_file -Value "`r`n" -ErrorAction SilentlyContinue
                    }

                    # Set AWS credentials
                    aws configure set aws_access_key_id $creds.AccessKeyId --profile $DEFAULT_SESSION
                    aws configure set aws_secret_access_key $creds.SecretAccessKey --profile $DEFAULT_SESSION
                    aws configure set aws_session_token $creds.SessionToken --profile $DEFAULT_SESSION
                    aws configure set region $DefaultRegion --profile $DEFAULT_SESSION

                    Write-Activity -Prefix 'AWS Manager' -Text "$TargetProfile profile has been updated in ~/.aws/credentials" -Stream 'Output'
                }

                # Renew CodeArtifact credentials
                Write-Activity -Prefix 'AWS Manager' -Text "Renewing $CodeArtifactProfile access keys..." -Stream 'Output'
                $credsCodeArtifactResult = aws sts assume-role --role-arn $target_role_codeartifact --role-session-name $User --profile $MFA_SESSION --query "Credentials" 2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    $creds_codeartifact = $credsCodeArtifactResult | ConvertFrom-Json
                    
                    # Add new lines to credentials files
                    if (-Not (Get-Content $creds_file -ErrorAction SilentlyContinue | Select-String $CodeArtifactProfile -quiet)) {
                        Add-Content -Path $creds_file -Value "`r`n" -ErrorAction SilentlyContinue
                    }

                    # Set CodeArtifact credentials
                    aws configure set aws_access_key_id $creds_codeartifact.AccessKeyId --profile $CODEARTIFACT_SESSION
                    aws configure set aws_secret_access_key $creds_codeartifact.SecretAccessKey --profile $CODEARTIFACT_SESSION
                    aws configure set aws_session_token $creds_codeartifact.SessionToken --profile $CODEARTIFACT_SESSION
                    aws configure set region $DefaultRegion --profile $CODEARTIFACT_SESSION

                    Write-Activity -Prefix 'AWS Manager' -Text "$CodeArtifactProfile profile has been updated in ~/.aws/credentials" -Stream 'Output'

                    # Get CodeArtifact authorization token
                    $CODEARTIFACT_AUTH_TOKEN = aws codeartifact get-authorization-token --domain nice-devops --domain-owner 369498121101 --query authorizationToken --output text --region us-west-2 --profile $CODEARTIFACT_SESSION 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Activity -Prefix 'AWS Manager' -Text 'Generated CodeArtifact token' -Stream 'Output'

                        # Update Maven settings.xml
                        try {
                            $file = "C:\Users\$env:UserName\.m2\settings.xml"
                            if (Test-Path $file) {
                                [xml]$x = Get-Content $file
                                $nodeId = $x.settings.servers.server | Where-Object { $_.id -eq "cxone-codeartifact" }
                                if ($nodeId) { $nodeId.password = $CODEARTIFACT_AUTH_TOKEN.ToString() }
                                $nodeId1 = $x.settings.servers.server | Where-Object { $_.id -eq "platform-utils" }
                                if ($nodeId1) { $nodeId1.password = $CODEARTIFACT_AUTH_TOKEN.ToString() }
                                $nodeId2 = $x.settings.servers.server | Where-Object { $_.id -eq "plugins-codeartifact" }
                                if ($nodeId2) { $nodeId2.password = $CODEARTIFACT_AUTH_TOKEN.ToString() }
                                $x.Save($file)
                                Write-Activity -Prefix 'AWS Manager' -Text "Updated $file with CodeArtifact token" -Stream 'Output'
                            }
                        } catch {
                            Write-Activity -Prefix 'AWS Manager' -Text "Could not update Maven settings.xml: $($_.Exception.Message)" -Stream 'Output'
                        }

                        # Update npm configuration
                        try {
                            npm config set registry "https://nice-devops-369498121101.d.codeartifact.us-west-2.amazonaws.com/npm/cxone-npm/" 2>$null | Out-Null
                            npm config set "//nice-devops-369498121101.d.codeartifact.us-west-2.amazonaws.com/npm/cxone-npm/:_authToken=$CODEARTIFACT_AUTH_TOKEN" 2>$null | Out-Null
                            Write-Activity -Prefix 'AWS Manager' -Text 'Updated npm configuration with CodeArtifact token' -Stream 'Output'
                        } catch {
                            Write-Activity -Prefix 'AWS Manager' -Text 'npm not installed or configuration failed' -Stream 'Output'
                        }
                    }
                }

                if ($hour -eq 1) {
                    Write-Activity -Prefix 'AWS Manager' -Text "Credentials will be renewed every 59 minutes for the next $hour hour" -Stream 'Output'
                } else {
                    Write-Activity -Prefix 'AWS Manager' -Text "Credentials will be renewed every 59 minutes for the next $hour hours" -Stream 'Output'
                }

                # Wait for 59 minutes or until stopped
                for ($i = 0; $i -lt 3540 -and -not $WPFGui.ScriptShouldStop; $i++) {
                    Start-Sleep -Seconds 1
                    if ($i % 60 -eq 0) {  # Update every minute
                        $minutesLeft = [math]::Floor((3540 - $i) / 60)
                        Write-StatusBar -Progress (25 + (31 * (37 - $hour) / 36)) -Text "Next renewal in $minutesLeft minutes... ($hour hours remaining)"
                    }
                }
            }

            if ($WPFGui.ScriptShouldStop) {
                Write-Activity -Prefix 'AWS Manager' -Text 'Credential renewal process stopped by user' -Stream 'Output'
            } else {
                Write-Activity -Prefix 'AWS Manager' -Text 'MFA token credentials have expired. Please restart the process.' -Stream 'Output'
            }

            Write-StatusBar -Progress 100 -Text "Process completed"
            return $true

        } catch {
            Write-Activity -Prefix 'AWS Manager' -Text "Error: $($_.Exception.Message)" -Stream 'Output' -IsError
            return $false
        }
    }
    $SessionFunctions.Add('Start-AWSCredentialProcessWithToken') | Out-Null

    # Create an Initial Session State for the ASync runspace and add all the functions in $SessionFunctions to it.
    $InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $SessionFunctions.ForEach({
            $SessionFunctionEntry = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($_, (Get-Content Function:\$_))
            $InitialSessionState.Commands.Add($SessionFunctionEntry) | Out-Null
        })

    #endregion Utility Functions

    #region - Setup default values

    # Development Mode Toggle
    $DevMode = $false

    # Failure Sentry
    $Failed = $false

    # Global variable to control script execution
    $WPFGui.Add('ScriptShouldStop', $false)
    $WPFGui.Add('ScriptRunning', $false)

    if ($MyInvocation.MyCommand.CommandType -eq "ExternalScript") { 
        $ScriptPath = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
    }
    else { 
        $ScriptPath = Split-Path -Parent -Path ([Environment]::GetCommandLineArgs()[0]) 
        if (!$ScriptPath) { $ScriptPath = "." } 
    }

    $WPFXaML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    x:Class="System.Windows.Window"
    Title="AWS Credential Manager"
    Width="900"
    MinWidth="900"
    Height="700"
    MinHeight="700"
    Name="CredentialWindow"
    AllowsTransparency="True"
    BorderThickness="0"
    WindowStartupLocation="CenterScreen"
    ResizeMode="CanResize"
    WindowStyle="None"
    Background="Transparent">
    <Window.Resources>
        <!-- Button Template -->
        <SolidColorBrush x:Key="Button.Static.Background" Color="#FFC2C2C2" />
        <SolidColorBrush x:Key="Button.Static.Border" Color="#FFC2C2C2" />
        <SolidColorBrush x:Key="Button.MouseOver.Background" Color="#FF005FB8" />
        <SolidColorBrush x:Key="Button.MouseOver.Border" Color="#FF005FB8" />
        <SolidColorBrush x:Key="Button.Pressed.Background" Color="#FF606060" />
        <SolidColorBrush x:Key="Button.Pressed.Border" Color="#FF606060" />
        <SolidColorBrush x:Key="Button.Default.Foreground" Color="White" />
        <SolidColorBrush x:Key="Button.Default.Background" Color="#FF005FB8" />
        <SolidColorBrush x:Key="Button.Default.Border" Color="#FF005FB8" />
        
        <Style TargetType="{x:Type Button}">
            <Setter Property="BorderBrush" Value="{StaticResource Button.Static.Border}" />
            <Setter Property="Background" Value="{StaticResource Button.Static.Border}" />
            <Setter Property="Foreground" Value="{DynamicResource {x:Static SystemColors.ControlTextBrushKey}}" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="HorizontalContentAlignment" Value="Center" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="Padding" Value="8,4,8,4" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border x:Name="border" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Background="{TemplateBinding Background}" SnapsToDevicePixels="true" CornerRadius="4">
                            <ContentPresenter x:Name="contentPresenter" Focusable="False" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True" SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsDefault" Value="true">
                    <Setter Property="BorderBrush" Value="{StaticResource Button.Default.Border}" />
                    <Setter Property="Background" Value="{StaticResource Button.Default.Background}" />
                    <Setter Property="Foreground" Value="{StaticResource Button.Default.Foreground}" />
                </Trigger>
                <Trigger Property="IsMouseOver" Value="true">
                    <Setter Property="Background" Value="{StaticResource Button.MouseOver.Background}" />
                    <Setter Property="BorderBrush" Value="{StaticResource Button.MouseOver.Border}" />
                    <Setter Property="Foreground" Value="White" />
                </Trigger>
                <Trigger Property="IsPressed" Value="true">
                    <Setter Property="Background" Value="{StaticResource Button.Pressed.Background}" />
                    <Setter Property="BorderBrush" Value="{StaticResource Button.Pressed.Border}" />
                </Trigger>
            </Style.Triggers>
        </Style>
        
        <!-- TextBox Template -->
        <SolidColorBrush x:Key="TextBox.Static.Border" Color="#7F7A7A7A" />
        <SolidColorBrush x:Key="TextBox.MouseOver.Border" Color="#FF005FB8" />
        <SolidColorBrush x:Key="TextBox.Focus.Border" Color="#FF005FB8" />
        <Style TargetType="{x:Type TextBox}">
            <Setter Property="Background" Value="{DynamicResource {x:Static SystemColors.WindowBrushKey}}" />
            <Setter Property="BorderBrush" Value="{StaticResource TextBox.Static.Border}" />
            <Setter Property="Foreground" Value="{DynamicResource {x:Static SystemColors.ControlTextBrushKey}}" />
            <Setter Property="BorderThickness" Value="0,0,0,1" />
            <Setter Property="FontFamily" Value="Segoe UI" />
            <Setter Property="KeyboardNavigation.TabNavigation" Value="None" />
            <Setter Property="HorizontalContentAlignment" Value="Left" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
            <Setter Property="FocusVisualStyle" Value="{x:Null}" />
            <Setter Property="AllowDrop" Value="true" />
            <Setter Property="ScrollViewer.PanningMode" Value="VerticalFirst" />
            <Setter Property="Stylus.IsFlicksEnabled" Value="False" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type TextBox}">
                        <Border x:Name="border" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Background="{TemplateBinding Background}" SnapsToDevicePixels="True" CornerRadius="4">
                            <ScrollViewer x:Name="PART_ContentHost" Focusable="false" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="false">
                                <Setter Property="Opacity" TargetName="border" Value="0.56" />
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="true">
                                <Setter Property="BorderBrush" TargetName="border" Value="{StaticResource TextBox.MouseOver.Border}" />
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="true">
                                <Setter Property="BorderBrush" TargetName="border" Value="{StaticResource TextBox.Focus.Border}" />
                                <Setter Property="BorderThickness" TargetName="border" Value="0,0,0,2" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="Window">
            <Style.Triggers>
                <Trigger Property="IsActive" Value="False">
                    <Setter Property="BorderBrush" Value="#FFAAAAAA" />
                </Trigger>
                <Trigger Property="IsActive" Value="True">
                    <Setter Property="BorderBrush" Value="#FF005FB8" />
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="32" ResizeBorderThickness="2" CornerRadius="8" />
    </WindowChrome.WindowChrome>

    <Border Name="WinBorder" BorderBrush="{Binding Path=BorderBrush, RelativeSource={RelativeSource AncestorType={x:Type Window}}}" BorderThickness="1" CornerRadius="8" Background="#FFF3F3F3">
        <Grid Name="MainGrid" Background="Transparent">
            <Grid.RowDefinitions>
                <RowDefinition Height="32" />
                <RowDefinition Height="*" />
                <RowDefinition Height="30" />
            </Grid.RowDefinitions>

            <!-- Titlebar -->
            <Border Grid.Row="0" CornerRadius="8,8,0,0" BorderThickness="0" Background="#FF005FB8">
                <DockPanel Height="32">
                    <Button DockPanel.Dock="Right" Name="CloseButton" Content="✕" Width="32" Height="32" Background="Transparent" BorderThickness="0" Foreground="White" FontSize="14" />
                    <Button DockPanel.Dock="Right" Name="MinimizeButton" Content="−" Width="32" Height="32" Background="Transparent" BorderThickness="0" Foreground="White" FontSize="14" />
                    <TextBlock DockPanel.Dock="Left" Margin="8,0" Text="AWS Credential Manager" TextAlignment="Center" HorizontalAlignment="Left" VerticalAlignment="Center" Foreground="White" FontWeight="Bold" />
                </DockPanel>
            </Border>

            <!-- Main Content -->
            <Grid Grid.Row="1" Margin="10">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="300" />
                    <ColumnDefinition Width="*" />
                </Grid.ColumnDefinitions>

                <!-- Configuration Panel -->
                <GroupBox Grid.Column="0" Header="Configuration" Margin="0,0,10,0" Padding="10">
                    <StackPanel>
                        <Label Content="AWS Username:" />
                        <TextBox Name="UserNameBox" Text="Avraham.Yom-Tov" Margin="0,0,0,10" />
                        
                        <Label Content="Target Profile Name:" />
                        <TextBox Name="TargetProfileBox" Text="test-dev" Margin="0,0,0,10" />
                        
                        <Label Content="Target Account Number:" />
                        <TextBox Name="TargetAccountBox" Text="211125581625" Margin="0,0,0,10" />
                        
                        <Label Content="CodeArtifact Profile:" />
                        <TextBox Name="CodeArtifactProfileBox" Text="nice-devops" Margin="0,0,0,10" />
                        
                        <Label Content="CodeArtifact Account:" />
                        <TextBox Name="CodeArtifactAccountBox" Text="369498121101" Margin="0,0,0,10" />
                        
                        <Label Content="Role Name:" />
                        <TextBox Name="RoleNameBox" Text="GroupAccess-Developers-Recording" Margin="0,0,0,10" />
                        
                        <Label Content="Source Profile:" />
                        <TextBox Name="SourceProfileBox" Text="nice-identity" Margin="0,0,0,10" />
                        
                        <Label Content="Default Region:" />
                        <TextBox Name="DefaultRegionBox" Text="us-west-2" Margin="0,0,0,10" />
                        
                        <StackPanel Orientation="Horizontal" Margin="0,20,0,0">
                            <Button Name="StartButton" Content="Start" Width="80" Margin="0,0,10,0" IsDefault="True" />
                            <Button Name="StopButton" Content="Stop" Width="80" IsEnabled="False" />
                        </StackPanel>
                    </StackPanel>
                </GroupBox>

                <!-- Output Panel -->
                <GroupBox Grid.Column="1" Header="Output" Padding="10">
                    <RichTextBox Name="Output" FontSize="12" FontFamily="Consolas" Background="{x:Null}" BorderBrush="{x:Null}" IsReadOnly="True" BorderThickness="0" VerticalScrollBarVisibility="Auto" />
                </GroupBox>
            </Grid>

            <!-- Status Area -->
            <Border Grid.Row="2" Margin="10,0,10,0" BorderThickness="0">
                <StatusBar Name="StatusArea" Background="{x:Null}">
                    <StatusBarItem>
                        <ProgressBar Name="Progress" Value="0" Width="200" />
                    </StatusBarItem>
                    <StatusBarItem>
                        <TextBlock Name="StatusText" Text="Ready." FontFamily="Verdana" />
                    </StatusBarItem>
                </StatusBar>
            </Border>
        </Grid>
    </Border>
</Window>
'@

    #endregion

    #region Build the GUI
    try {
        $WPFGui = [hashtable]::Synchronized( (New-WPFDialog -XamlData $WPFXamL) )
    }
    catch {
        $failed = $true
    }

    $WPFGui.Add('hWnd', $null)
    #endregion

    #region Titlebar buttons
    $WPFGui.MinimizeButton.add_Click( {
            $WPFGui.UI.WindowState = 'Minimized'
        })

    $WPFGui.CloseButton.add_Click( {
            $WPFGui.ScriptShouldStop = $true
            $WPFGui.UI.Close()
        })

    #region Button Event Handlers

    $WPFGui.StartButton.add_Click({
        try {
            Write-Activity -Prefix 'AWS Manager' -Text 'Start button clicked...' -Stream 'Output'
            
            # Disable start button and enable stop button
            $WPFGui.StartButton.IsEnabled = $false
            $WPFGui.StopButton.IsEnabled = $true
            $WPFGui.ScriptShouldStop = $false
            $WPFGui.ScriptRunning = $true

            # Disable configuration fields while running
            $WPFGui.UserNameBox.IsEnabled = $false
            $WPFGui.TargetProfileBox.IsEnabled = $false
            $WPFGui.TargetAccountBox.IsEnabled = $false
            $WPFGui.CodeArtifactProfileBox.IsEnabled = $false
            $WPFGui.CodeArtifactAccountBox.IsEnabled = $false
            $WPFGui.RoleNameBox.IsEnabled = $false
            $WPFGui.SourceProfileBox.IsEnabled = $false
            $WPFGui.DefaultRegionBox.IsEnabled = $false

            # Clear output
            $WPFGui.Output.Document.Blocks.Clear()
            
            # Get MFA token BEFORE starting async process (to avoid UI thread issues)
            Write-Activity -Prefix 'AWS Manager' -Text 'Getting MFA token...' -Stream 'Output'
            
            $MfaDialog = New-MessageDialog -DialogTitle "MFA Required" -H1 "Enter MFA Code" -DialogText "Please enter your MFA token code:" -ConfirmText "OK" -CancelText "Cancel" -GetInput -Owner $WPFGui.UI

            if ($MfaDialog.DialogResult -eq [System.Windows.Forms.DialogResult]::Cancel) {
                Write-Activity -Prefix 'AWS Manager' -Text 'MFA input cancelled by user' -Stream 'Output' -IsError
                
                # Re-enable controls
                $WPFGui.StartButton.IsEnabled = $true
                $WPFGui.StopButton.IsEnabled = $false
                $WPFGui.ScriptRunning = $false
                
                # Re-enable configuration fields
                $WPFGui.UserNameBox.IsEnabled = $true
                $WPFGui.TargetProfileBox.IsEnabled = $true
                $WPFGui.TargetAccountBox.IsEnabled = $true
                $WPFGui.CodeArtifactProfileBox.IsEnabled = $true
                $WPFGui.CodeArtifactAccountBox.IsEnabled = $true
                $WPFGui.RoleNameBox.IsEnabled = $true
                $WPFGui.SourceProfileBox.IsEnabled = $true
                $WPFGui.DefaultRegionBox.IsEnabled = $true
                return
            }

            $mfa_token = $MfaDialog.Text
            if ([string]::IsNullOrWhiteSpace($mfa_token)) {
                Write-Activity -Prefix 'AWS Manager' -Text 'MFA token cannot be empty' -Stream 'Output' -IsError
                
                # Re-enable controls
                $WPFGui.StartButton.IsEnabled = $true
                $WPFGui.StopButton.IsEnabled = $false
                $WPFGui.ScriptRunning = $false
                
                # Re-enable configuration fields
                $WPFGui.UserNameBox.IsEnabled = $true
                $WPFGui.TargetProfileBox.IsEnabled = $true
                $WPFGui.TargetAccountBox.IsEnabled = $true
                $WPFGui.CodeArtifactProfileBox.IsEnabled = $true
                $WPFGui.CodeArtifactAccountBox.IsEnabled = $true
                $WPFGui.RoleNameBox.IsEnabled = $true
                $WPFGui.SourceProfileBox.IsEnabled = $true
                $WPFGui.DefaultRegionBox.IsEnabled = $true
                return
            }
            
            Write-Activity -Prefix 'AWS Manager' -Text 'Starting async process...' -Stream 'Output'
            
            # Start the process asynchronously
            $AsyncParameters = @{
                Variables = @{
                    WPFGui = $WPFGui
                    User = $WPFGui.UserNameBox.Text
                    TargetProfile = $WPFGui.TargetProfileBox.Text
                    TargetAccount = $WPFGui.TargetAccountBox.Text
                    CodeArtifactProfile = $WPFGui.CodeArtifactProfileBox.Text
                    CodeArtifactAccount = $WPFGui.CodeArtifactAccountBox.Text
                    RoleName = $WPFGui.RoleNameBox.Text
                    SourceProfile = $WPFGui.SourceProfileBox.Text
                    DefaultRegion = $WPFGui.DefaultRegionBox.Text
                    MfaToken = $mfa_token
                }
                Code = {
                    Write-Activity -Prefix 'AWS Manager' -Text 'Inside async runspace...' -Stream 'Output'
                    
                    # Check if AWS CLI is available
                    try {
                        $awsVersion = aws --version 2>&1
                        Write-Activity -Prefix 'AWS Manager' -Text "AWS CLI version: $awsVersion" -Stream 'Output'
                    } catch {
                        Write-Activity -Prefix 'AWS Manager' -Text 'AWS CLI not found. Please install AWS CLI first.' -Stream 'Output' -IsError
                        return
                    }

                    # Start the credential process (with MFA token already obtained)
                    Start-AWSCredentialProcessWithToken -User $User -TargetProfile $TargetProfile -TargetAccount $TargetAccount -CodeArtifactProfile $CodeArtifactProfile -CodeArtifactAccount $CodeArtifactAccount -RoleName $RoleName -SourceProfile $SourceProfile -DefaultRegion $DefaultRegion -MfaToken $MfaToken

                    # Re-enable controls when done
                    $WPFGui.UI.Dispatcher.Invoke([action]{
                        $WPFGui.StartButton.IsEnabled = $true
                        $WPFGui.StopButton.IsEnabled = $false
                        $WPFGui.ScriptRunning = $false
                        
                        # Re-enable configuration fields
                        $WPFGui.UserNameBox.IsEnabled = $true
                        $WPFGui.TargetProfileBox.IsEnabled = $true
                        $WPFGui.TargetAccountBox.IsEnabled = $true
                        $WPFGui.CodeArtifactProfileBox.IsEnabled = $true
                        $WPFGui.CodeArtifactAccountBox.IsEnabled = $true
                        $WPFGui.RoleNameBox.IsEnabled = $true
                        $WPFGui.SourceProfileBox.IsEnabled = $true
                        $WPFGui.DefaultRegionBox.IsEnabled = $true
                        
                        Write-StatusBar -Progress 0 -Text "Ready"
                    })
                }
            }
            
            Invoke-Async @AsyncParameters
            Write-Activity -Prefix 'AWS Manager' -Text 'Async process started successfully' -Stream 'Output'
            
        } catch {
            Write-Activity -Prefix 'AWS Manager' -Text "Error in Start button click: $($_.Exception.Message)" -Stream 'Output' -IsError
            
            # Re-enable controls on error
            $WPFGui.StartButton.IsEnabled = $true
            $WPFGui.StopButton.IsEnabled = $false
            $WPFGui.ScriptRunning = $false
        }
    })

    $WPFGui.StopButton.add_Click({
        $WPFGui.ScriptShouldStop = $true
        Write-Activity -Prefix 'AWS Manager' -Text 'Stop requested by user...' -Stream 'Output'
        Write-StatusBar -Progress 0 -Text "Stopping..."
        
        # Re-enable start button immediately
        $WPFGui.StartButton.IsEnabled = $true
        $WPFGui.StopButton.IsEnabled = $false
    })

    #endregion

    $WPFGui.UI.add_ContentRendered( {
        # Once the window is visible, grab handle to it
        if ( $WPFGui.hWnd -eq $null) {
            $WPFGui.hWnd = (New-Object System.Windows.Interop.WindowInteropHelper($WPFGui.UI)).Handle
        }
        [System.Win32Util]::SetTop($WPFGui.hWnd)

        # Write initial log entry
        Write-Activity -Prefix 'AWS Manager' -Text 'AWS Credential Manager started successfully' -Stream 'Output'
        Write-StatusBar -Progress 0 -Text "Ready"
    })

    if ( -not $Failed ) {
        # Setup async runspace items
        $WPFGui.Host = $host
        $WPFGui.Add('Runspace', [runspacefactory]::CreateRunspace($InitialSessionState))
        $WPFGui.Runspace.ApartmentState = "STA"
        $WPFGui.Runspace.ThreadOptions = "ReuseThread"
        $WPFGui.Runspace.Open()
        $WPFGui.UI.Dispatcher.InvokeAsync{ $WPFGui.UI.ShowDialog() }.Wait()
        $WPFGui.Runspace.Close()
        $WPFGui.Runspace.Dispose()
    }
})
$psCmd.Runspace = $newRunspace
$data = $psCmd.Invoke() 