# AWS Credential Manager with GUI FOR EASY USE OF AWS CREDENTIALS DEVELOPMENT

#region Global Variables and Configuration



$Global:IsRunning = $false
$Global:CurrentJob = $null
$Global:StopRequested = $false

# Configuration - Update these with your values ..
$user = 'Avraham.Yom-Tov' 
$DEFAULT_SESSION = "default"
$default_region = 'us-west-2'
$source_profile = 'nice-identity' 
$main_iam_acct_num = '736763050260'
$MFA_SESSION = "$source_profile-mfa-session"
$CODEARTIFACT_SESSION = "default-codeartifact"
$role_name = 'GroupAccess-Developers-Recording'
$target_account_num_codeartifact = '369498121101' 
$m2_config_file = "C:\Users\$env:UserName\.m2\settings.xml"
$target_profile_name_codeartifact = 'GroupAccess-NICE-Developers' 


#region Account LisT ( selection - you can add more accounts here if needed )
$Global:AccountList = @(

    [PSCustomObject]@{ AccountId = 730335479582; Name = "rec-dev" }
    [PSCustomObject]@{ AccountId = 211125581625; Name = "rec-test" }
    [PSCustomObject]@{ AccountId = 339712875220; Name = "rec-perf" }
    [PSCustomObject]@{ AccountId = 891377049518; Name = "rec-staging" }
    [PSCustomObject]@{ AccountId = 934137132601; Name = "dev-test-perf" }
)


# Add required assemblies at the top level
try {
    Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Drawing, System.Windows.Forms
    Write-Host "WPF assemblies loaded successfully"
} catch {
    Write-Error "Failed to load WPF assemblies: $($_.Exception.Message)"
    exit 1
}

#region Utility Functions
function Update-Status {
    param(
        [string]$Message,
        [int]$Progress = -1
    )
    
    if ($WPFGui.UI) {
        $WPFGui.UI.Dispatcher.Invoke([Action]{
            $WPFGui.StatusText.Content = $Message
            if ($Progress -ge 0) {
                $WPFGui.ProgressBar.Value = $Progress
            }
        })
    }
}

function Write-Log {
    param([string]$Message)
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    
    if ($WPFGui.UI) {
        $WPFGui.UI.Dispatcher.Invoke([Action]{
            $WPFGui.LogOutput.AppendText("$logMessage`n")
            $WPFGui.LogOutput.ScrollToEnd()
        })
    }
    
    # Write to console for debugging ( dev)
    Write-Host $logMessage
}

function Show-MFADialog {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MFA Authentication" Height="200" Width="400"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <TextBlock Grid.Row="0" Text="Enter MFA Code" FontSize="16" FontWeight="Bold" Margin="0,0,0,10"/>
        <TextBlock Grid.Row="1" Text="Please enter your 6-digit MFA code:" Margin="0,0,0,10"/>
        <TextBox Grid.Row="2" Name="MFATextBox" FontSize="14" Padding="5" Margin="0,0,0,10"/>
        
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="OKButton" Content="OK" Width="75" Height="30" Margin="0,0,10,0" IsDefault="True"/>
            <Button Name="CancelButton" Content="Cancel" Width="75" Height="30" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@

    try {
        $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
        $dialog = [Windows.Markup.XamlReader]::Load($reader)
        
        $mfaTextBox = $dialog.FindName("MFATextBox")
        $okButton = $dialog.FindName("OKButton")
        $cancelButton = $dialog.FindName("CancelButton")
        
        $okButton.Add_Click({
            $dialog.DialogResult = $true
            $dialog.Close()
        })
        
        $cancelButton.Add_Click({
            $dialog.DialogResult = $false
            $dialog.Close()
        })
        
        if ($WPFGui.UI) {
            $dialog.Owner = $WPFGui.UI
        }
        $result = $dialog.ShowDialog()
        
        if ($result -eq $true) {
            return $mfaTextBox.Text
        }
        return $null
    } catch {
        Write-Host "Error showing MFA dialog: $($_.Exception.Message)"
        return $null
    }
}

function addNewLine {
    param([string] $target_profile_name)
    
    $creds_file = "~/.aws/credentials"
    if (Test-Path $creds_file) {
        if (-Not (Get-Content $creds_file -ErrorAction SilentlyContinue | Select-String "$target_profile_name" -quiet)) {
            Add-Content -Path $creds_file -Value "`r`n"
        }
    }
    $config_file = "~/.aws/config"
    if (Test-Path $config_file) {
        if (-Not (Get-Content $config_file -ErrorAction SilentlyContinue | Select-String "$target_profile_name" -quiet)) {
            Add-Content -Path $config_file -Value "`r`n"
        }
    }
}

#region XAML Definition ( GUI )
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AWS Credential Manager" Height="700" Width="900"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <!-- Header -->
        <Border Grid.Row="0" Background="#FF2B579A" Padding="10">
            <TextBlock Text="AWS Credential Manager" FontSize="20" FontWeight="Bold" Foreground="White"/>
        </Border>
        
        <!-- Account Selection -->
        <GroupBox Grid.Row="1" Header="Account Selection" Margin="10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Select Account:" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <ComboBox Grid.Column="1" Name="AccountComboBox" DisplayMemberPath="Name" Height="30" FontSize="12"/>
            </Grid>
        </GroupBox>
        
        <!-- Control Buttons -->
        <GroupBox Grid.Row="2" Header="Controls" Margin="10">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                <Button Name="StartButton" Content="Start" Width="100" Height="35" Margin="5" FontSize="12" Background="#FF4CAF50" Foreground="White"/>
                <Button Name="StopButton" Content="Stop" Width="100" Height="35" Margin="5" FontSize="12" Background="#FFF44336" Foreground="White" IsEnabled="False"/>
                <Button Name="RestartButton" Content="Restart" Width="100" Height="35" Margin="5" FontSize="12" Background="#FFFF9800" Foreground="White"/>
            </StackPanel>
        </GroupBox>
        
        <!-- Log Output -->
        <GroupBox Grid.Row="3" Header="Activity Log" Margin="10">
            <ScrollViewer>
                <TextBox Name="LogOutput" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" 
                         Background="#FFF5F5F5" FontFamily="Consolas" FontSize="10"/>
            </ScrollViewer>
        </GroupBox>
        
        <!-- Progress Bar -->
        <GroupBox Grid.Row="4" Header="Progress" Margin="10">
            <ProgressBar Name="ProgressBar" Height="20" Minimum="0" Maximum="100" Value="0"/>
        </GroupBox>
        
        <!-- Status Bar -->
        <StatusBar Grid.Row="5" Background="#FFF0F0F0">
            <StatusBarItem>
                <Label Name="StatusText" Content="Ready" FontSize="11"/>
            </StatusBarItem>
        </StatusBar>
    </Grid>
</Window>
'@
#endregion

# Initialize the GUI hashtable
$Global:WPFGui = @{}

try {
    Write-Host "Loading GUI ..."
    
    # Load the XAML
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $Global:WPFGui.UI = [Windows.Markup.XamlReader]::Load($reader)
    
    if (-not $Global:WPFGui.UI) {
        throw "Failed to create main window"
    }
    
    Write-Host "GUI window created successfully"
    
    # Get references to controls
    $Global:WPFGui.AccountComboBox = $Global:WPFGui.UI.FindName("AccountComboBox")
    $Global:WPFGui.StartButton = $Global:WPFGui.UI.FindName("StartButton")
    $Global:WPFGui.StopButton = $Global:WPFGui.UI.FindName("StopButton")
    $Global:WPFGui.RestartButton = $Global:WPFGui.UI.FindName("RestartButton")
    $Global:WPFGui.LogOutput = $Global:WPFGui.UI.FindName("LogOutput")
    $Global:WPFGui.ProgressBar = $Global:WPFGui.UI.FindName("ProgressBar")
    $Global:WPFGui.StatusText = $Global:WPFGui.UI.FindName("StatusText")

    # Verify all controls were found
    $controls = @("AccountComboBox", "StartButton", "StopButton", "RestartButton", "LogOutput", "ProgressBar", "StatusText")
    foreach ($control in $controls) {
        if (-not $Global:WPFGui[$control]) {
            Write-Warning "Control $control not found!"
        } else {
            Write-Host "Control $control found successfully"
        }
    }

    # Populate account dropdown
    $Global:WPFGui.AccountComboBox.ItemsSource = $Global:AccountList
    $Global:WPFGui.AccountComboBox.SelectedIndex = 0

    Write-Log "AWS Credential Manager GUI loaded successfully."
    Write-Log "Select an account and click Start to begin the credential process."

} catch {
    Write-Host "Error loading GUI: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace: $($_.Exception.StackTrace)" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

#region Event Handlers
$Global:WPFGui.StartButton.Add_Click({
    try {
        if ($Global:IsRunning) {
            return
        }

        $selectedAccount = $Global:WPFGui.AccountComboBox.SelectedItem
        if (-not $selectedAccount) {
            [System.Windows.MessageBox]::Show("Please select an account first.", "No Account Selected", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }

        $mfaCode = Show-MFADialog
        if (-not $mfaCode) {
            Write-Log "MFA authentication cancelled by user."
            return
        }

        if ($mfaCode.Length -ne 6 -or -not ($mfaCode -match '^\d{6}$')) {
            [System.Windows.MessageBox]::Show("Please enter a valid 6-digit MFA code.", "Invalid MFA Code", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }

        Write-Log "Starting AWS credential process for $($selectedAccount.Name) ($($selectedAccount.AccountId))"
        
        $Global:WPFGui.StartButton.IsEnabled = $false
        $Global:WPFGui.StopButton.IsEnabled = $true
        $Global:WPFGui.RestartButton.IsEnabled = $false

        # Start background job using PowerShell jobs instead of runspaces for simplicity
        $Global:CurrentJob = Start-Job -ScriptBlock {
            param($SelectedAccount, $MFACode, $user, $target_profile_name_codeartifact, $target_account_num_codeartifact, $role_name, $source_profile, $main_iam_acct_num, $default_region, $MFA_SESSION, $DEFAULT_SESSION, $CODEARTIFACT_SESSION, $m2_config_file)
            
            function addNewLine {
                param([string] $target_profile_name)
                $creds_file = "$env:USERPROFILE\.aws\credentials"
                if (Test-Path $creds_file) {
                    if (-Not (Get-Content $creds_file -ErrorAction SilentlyContinue | Select-String "$target_profile_name" -quiet)) {
                        Add-Content -Path $creds_file -Value "`r`n"
                    }
                }
                $config_file = "$env:USERPROFILE\.aws\config"
                if (Test-Path $config_file) {
                    if (-Not (Get-Content $config_file -ErrorAction SilentlyContinue | Select-String "$target_profile_name" -quiet)) {
                        Add-Content -Path $config_file -Value "`r`n"
                    }
                }
            }
            
            try {
                $target_account_num = $SelectedAccount.AccountId
                $target_profile_name = $SelectedAccount.Name
                $mfa_device = "arn:aws:iam::" + $main_iam_acct_num + ":mfa/" + $user
                $token_expiration_seconds = 129600 # 36 Hours
                $target_role = "arn:aws:iam::" + $target_account_num + ":role/" + $role_name
                $target_role_codeartifact = "arn:aws:iam::" + $target_account_num_codeartifact + ":role/" + $role_name

                # Get session token with MFA
                Write-Output "Getting session token with MFA..."
                $token_result = aws sts get-session-token --serial-number $mfa_device --duration-seconds $token_expiration_seconds --token-code $MFACode --profile $source_profile 2>&1

                if ($LASTEXITCODE -ne 0) {
                    Write-Output "AWS CLI Error: $token_result"
                    throw "Failed to get session token. Please check your MFA code and AWS configuration."
                }
                
                try {
                    $token_creds = $token_result | ConvertFrom-Json
                } catch {
                    Write-Output "Error parsing AWS response: $token_result"
                    throw "Failed to parse AWS response. Please check your AWS configuration."
                }
                
                # Set AWS credentials via CLI
                aws configure set aws_access_key_id $token_creds.Credentials.AccessKeyId --profile "$MFA_SESSION"
                aws configure set aws_secret_access_key $token_creds.Credentials.SecretAccessKey --profile "$MFA_SESSION"
                aws configure set aws_session_token $token_creds.Credentials.SessionToken --profile "$MFA_SESSION"
                aws configure set region $default_region --profile $target_profile_name
                aws configure set region $default_region --profile $target_profile_name_codeartifact

                Write-Output "Successfully cached token for $token_expiration_seconds seconds .."

                # Start the renewal loop for 36 hours
                for ($hour = 36; $hour -gt 0; $hour--) {
                    try {
                        Write-Output "Renewing $target_profile_name access keys... ($hour hours remaining)"

                        $creds = aws sts assume-role --role-arn $target_role --role-session-name $user --profile "$MFA_SESSION" --query "Credentials" | ConvertFrom-Json
                        $creds_codeartifact = aws sts assume-role --role-arn $target_role_codeartifact --role-session-name $user --profile "$MFA_SESSION" --query "Credentials" | ConvertFrom-Json

                        if ($LASTEXITCODE -eq 0) {
                            addNewLine $target_profile_name 
                            
                            # Set AWS credentials via CLI
                            aws configure set aws_access_key_id $creds.AccessKeyId --profile "$DEFAULT_SESSION"
                            aws configure set aws_secret_access_key $creds.SecretAccessKey --profile "$DEFAULT_SESSION"
                            aws configure set aws_session_token $creds.SessionToken --profile "$DEFAULT_SESSION"
                            aws configure set region $default_region --profile "$DEFAULT_SESSION"
                            
                            Write-Output "$target_profile_name profile has been updated in ~/.aws/credentials."
                            
                            addNewLine $target_profile_name_codeartifact
                            
                            aws configure set aws_access_key_id $creds_codeartifact.AccessKeyId --profile "$CODEARTIFACT_SESSION"
                            aws configure set aws_secret_access_key $creds_codeartifact.SecretAccessKey --profile "$CODEARTIFACT_SESSION"
                            aws configure set aws_session_token $creds_codeartifact.SessionToken --profile "$CODEARTIFACT_SESSION"
                            aws configure set region $default_region --profile "$CODEARTIFACT_SESSION"

                            Write-Output "$target_profile_name_codeartifact profile has been updated in ~/.aws/credentials."
                            
                            # Get CodeArtifact token
                            $CODEARTIFACT_AUTH_TOKEN = (aws codeartifact get-authorization-token --domain nice-devops --domain-owner 369498121101 --query authorizationToken --output text --region us-west-2 --profile "$CODEARTIFACT_SESSION")
                            Write-Output "Generated CodeArtifact Token."
                            
                            # Update Maven settings.xml
                            try {
                                if (Test-Path $m2_config_file) {
                                    $x = [xml] (Get-Content $m2_config_file)
                                    $nodeId = $x.settings.servers.server | Where-Object { $_.id -eq "cxone-codeartifact" }
                                    if ($nodeId) { $nodeId.password = $CODEARTIFACT_AUTH_TOKEN.ToString() }
                                    $nodeId1 = $x.settings.servers.server | Where-Object { $_.id -eq "platform-utils" }
                                    if ($nodeId1) { $nodeId1.password = $CODEARTIFACT_AUTH_TOKEN.ToString() }
                                    $nodeId2 = $x.settings.servers.server | Where-Object { $_.id -eq "plugins-codeartifact" }
                                    if ($nodeId2) { $nodeId2.password = $CODEARTIFACT_AUTH_TOKEN.ToString() }
                                    $x.Save($m2_config_file)
                                    Write-Output "Updated $m2_config_file with CodeArtifact Token."
                                }
                            } catch {
                                Write-Output "No settings.xml found or using old version: $($_.Exception.Message)"
                            }
                            
                            # Update NPM config
                            try {
                                npm config set registry "https://nice-devops-369498121101.d.codeartifact.us-west-2.amazonaws.com/npm/cxone-npm/" 2>$null
                                npm config set "//nice-devops-369498121101.d.codeartifact.us-west-2.amazonaws.com/npm/cxone-npm/:_authToken=${CODEARTIFACT_AUTH_TOKEN}" 2>$null
                                Write-Output "Updated NPM with CodeArtifact Token."
                            } catch {
                                Write-Output "NPM not installed or error: $($_.Exception.Message)"
                            }

                            $hourText = if ($hour -eq 1) { "hour" } else { "hours" }
                            Write-Output "Credentials renewed successfully. Sleeping for 59 minutes... ($hour $hourText remaining)"

                            # Sleep for 59 minutes
                            Start-Sleep -Seconds 3540
                        } else {
                            throw "Failed to assume role"
                        }
                    } catch {
                        Write-Output "Error during renewal: $($_.Exception.Message)"
                        break
                    }
                }
                
                Write-Output "MFA token credentials have expired after 36 hours."

            } catch {
                Write-Output "Error: $($_.Exception.Message)"
            }
        } -ArgumentList $selectedAccount, $mfaCode, $user, $target_profile_name_codeartifact, $target_account_num_codeartifact, $role_name, $source_profile, $main_iam_acct_num, $default_region, $MFA_SESSION, $DEFAULT_SESSION, $CODEARTIFACT_SESSION, $m2_config_file

        # Monitor the job
        $Global:JobTimer = New-Object System.Windows.Threading.DispatcherTimer
        $Global:JobTimer.Interval = [TimeSpan]::FromSeconds(2)
        $Global:JobTimer.Add_Tick({
            try {
                # Check if UI still exists
                if (-not $Global:WPFGui -or -not $Global:WPFGui.UI) {
                    if ($Global:JobTimer) { $Global:JobTimer.Stop() }
                    return
                }
                
                if ($Global:CurrentJob) {
                    try {
                        $jobOutput = Receive-Job -Job $Global:CurrentJob -ErrorAction SilentlyContinue
                        if ($jobOutput) {
                            foreach ($line in $jobOutput) {
                                try {
                                    Write-Log $line
                                } catch {
                                    # Ignore log errors
                                }
                            }
                        }
                        
                        if ($Global:CurrentJob.State -eq 'Completed' -or $Global:CurrentJob.State -eq 'Failed' -or $Global:CurrentJob.State -eq 'Stopped') {
                            if ($Global:JobTimer) { $Global:JobTimer.Stop() }
                            $Global:IsRunning = $false
                            
                            # Safely update UI controls
                            try {
                                if ($Global:WPFGui.StartButton) { $Global:WPFGui.StartButton.IsEnabled = $true }
                                if ($Global:WPFGui.StopButton) { $Global:WPFGui.StopButton.IsEnabled = $false }
                                if ($Global:WPFGui.RestartButton) { $Global:WPFGui.RestartButton.IsEnabled = $true }
                            } catch {
                                # Ignore UI update errors
                            }
                            
                            if ($Global:CurrentJob.State -eq 'Failed') {
                                try {
                                    if ($Global:CurrentJob.ChildJobs -and $Global:CurrentJob.ChildJobs.Count -gt 0) {
                                        $reason = $Global:CurrentJob.ChildJobs[0].JobStateInfo.Reason
                                        if ($reason) {
                                            Write-Log "Job failed: $reason"
                                        } else {
                                            Write-Log "Job failed: Unknown reason"
                                        }
                                    } else {
                                        Write-Log "Job failed: No detailed error information available"
                                    }
                                } catch {
                                    try {
                                        Write-Log "Job failed: Error retrieving failure details"
                                    } catch {
                                        # Ignore even log errors
                                    }
                                }
                            }
                            
                            try {
                                Remove-Job -Job $Global:CurrentJob -Force -ErrorAction SilentlyContinue
                            } catch {
                                # Ignore cleanup errors
                            }
                            $Global:CurrentJob = $null
                            
                            try {
                                Update-Status "Ready" 0
                            } catch {
                                # Ignore status update errors
                            }
                        }
                    } catch {
                        # Error accessing job, likely job was removed
                        if ($Global:JobTimer) { $Global:JobTimer.Stop() }
                        $Global:CurrentJob = $null
                        $Global:IsRunning = $false
                    }
                } else {
                    # Job is null, stop the timer
                    if ($Global:JobTimer) { $Global:JobTimer.Stop() }
                }
            } catch {
                # Complete error handler - stop everything
                try {
                    Write-Host "Error in job monitoring: $($_.Exception.Message)"
                } catch {
                    # Even console output failed
                }
                
                try {
                    if ($Global:JobTimer) { $Global:JobTimer.Stop() }
                } catch {
                    # Ignore timer stop errors
                }
                
                $Global:IsRunning = $false
                $Global:CurrentJob = $null
            }
        })
        $Global:JobTimer.Start()
        
        $Global:IsRunning = $true
        
    } catch {
        Write-Log "Error in Start button click: $($_.Exception.Message)"
        $Global:WPFGui.StartButton.IsEnabled = $true
        $Global:WPFGui.StopButton.IsEnabled = $false
        $Global:WPFGui.RestartButton.IsEnabled = $true
    }
})

$Global:WPFGui.StopButton.Add_Click({
    try {
        $Global:StopRequested = $true
        Write-Log "Stop requested by user. Stopping process..."
        Update-Status "Stopping process..." 0
        $Global:WPFGui.StopButton.IsEnabled = $false
        
        if ($Global:CurrentJob) {
            try {
                Stop-Job -Job $Global:CurrentJob -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500  # Give job time to stop
                Remove-Job -Job $Global:CurrentJob -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Log "Warning: Error during job cleanup: $($_.Exception.Message)"
            } finally {
                $Global:CurrentJob = $null
            }
        }
        
        # Stop the timer
        if ($Global:JobTimer) {
            try {
                $Global:JobTimer.Stop()
                $Global:JobTimer = $null
            } catch {
                # Ignore timer cleanup errors
            }
        }
        
        $Global:IsRunning = $false
        $Global:WPFGui.StartButton.IsEnabled = $true
        $Global:WPFGui.RestartButton.IsEnabled = $true
        Write-Log "Process stopped successfully."
    } catch {
        Write-Log "Error in Stop button click: $($_.Exception.Message)"
    }
})

$Global:WPFGui.RestartButton.Add_Click({
    try {
        if ($Global:IsRunning) {
            $Global:StopRequested = $true
            Write-Log "Restarting process..."
            
            if ($Global:CurrentJob) {
                try {
                    Stop-Job -Job $Global:CurrentJob -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500  # Give job time to stop
                    Remove-Job -Job $Global:CurrentJob -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Log "Warning: Error during job cleanup: $($_.Exception.Message)"
                } finally {
                    $Global:CurrentJob = $null
                }
            }
            
            # Stop the timer
            if ($Global:JobTimer) {
                try {
                    $Global:JobTimer.Stop()
                    $Global:JobTimer = $null
                } catch {
                    # Ignore timer cleanup errors
                }
            }
            
            Start-Sleep -Seconds 1
        }
        
        # Reset state
        $Global:IsRunning = $false
        
        # Clear the log
        $Global:WPFGui.LogOutput.Clear()
        $Global:WPFGui.ProgressBar.Value = 0
        Update-Status "Ready" 0
        
        # Reset button states
        $Global:WPFGui.StartButton.IsEnabled = $true
        $Global:WPFGui.StopButton.IsEnabled = $false
        $Global:WPFGui.RestartButton.IsEnabled = $true
        
        Write-Log "Ready to start new process"
    } catch {
        Write-Log "Error in Restart button click: $($_.Exception.Message)"
    }
})

$Global:WPFGui.UI.Add_Closing({
    try {
        $Global:StopRequested = $true
        
        # Stop the timer first
        if ($Global:JobTimer) {
            try {
                $Global:JobTimer.Stop()
                $Global:JobTimer = $null
            } catch {
                # Ignore timer cleanup errors
            }
        }
        
        # Then clean up the job
        if ($Global:CurrentJob) {
            Stop-Job -Job $Global:CurrentJob -ErrorAction SilentlyContinue
            Remove-Job -Job $Global:CurrentJob -Force -ErrorAction SilentlyContinue
            $Global:CurrentJob = $null
        }
    } catch {
        # Ignore errors during cleanup
    }
})
#endregion

# Show the GUI
try {
    Write-Host "Showing GUI window..."
    if ($Global:WPFGui.UI) {
        $Global:WPFGui.UI.ShowDialog() | Out-Null
    } else {
        throw "GUI window was not created successfully"
    }
} catch {
    Write-Host "Error showing GUI: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Full error details: $($_.Exception.ToString())" -ForegroundColor Red
    if ($Global:CurrentJob) {
        try {
            Stop-Job -Job $Global:CurrentJob -ErrorAction SilentlyContinue
            Remove-Job -Job $Global:CurrentJob -Force -ErrorAction SilentlyContinue
        } catch {
            # Ignore cleanup errors
        }
    }
    Read-Host "Press Enter to exit"
}