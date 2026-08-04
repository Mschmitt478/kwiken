function ConvertTo-WindowsCommandLineArgument {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Argument
  )

  if ($Argument.IndexOf([char]0) -ge 0) {
    throw "Process arguments cannot contain a null character."
  }

  if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
    return $Argument
  }

  # ProcessStartInfo.Arguments is a single command-line string on Windows
  # PowerShell 5.1. Quote each argument according to CommandLineToArgvW rules so
  # whitespace, embedded quotes, and backslashes before quotes survive intact.
  $builder = [Text.StringBuilder]::new()
  [void]$builder.Append([char]34)
  $backslashCount = 0

  foreach ($character in $Argument.ToCharArray()) {
    if ($character -eq [char]92) {
      $backslashCount++
      continue
    }

    if ($character -eq [char]34) {
      [void]$builder.Append([string]::new([char]92, (2 * $backslashCount) + 1))
      [void]$builder.Append([char]34)
      $backslashCount = 0
      continue
    }

    if ($backslashCount -gt 0) {
      [void]$builder.Append([string]::new([char]92, $backslashCount))
      $backslashCount = 0
    }
    [void]$builder.Append($character)
  }

  if ($backslashCount -gt 0) {
    [void]$builder.Append([string]::new([char]92, 2 * $backslashCount))
  }
  [void]$builder.Append([char]34)
  return $builder.ToString()
}

function Join-WindowsCommandLineArguments {
  param(
    [AllowEmptyCollection()]
    [string[]]$Arguments = @()
  )

  $quotedArguments = foreach ($argument in $Arguments) {
    if ($null -eq $argument) {
      throw "Process arguments cannot be null."
    }
    ConvertTo-WindowsCommandLineArgument -Argument $argument
  }
  return ($quotedArguments -join ' ')
}

function Start-KwikenBrowserProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$Arguments = @(),
    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory
  )

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = Join-WindowsCommandLineArguments -Arguments $Arguments
  $startInfo.WorkingDirectory = $WorkingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $false

  $process = [Diagnostics.Process]::Start($startInfo)
  if ($null -eq $process) {
    throw "Windows did not return a process after starting $FilePath."
  }
  return $process
}

function Stop-KwikenProcessAfterStartupFailure {
  param(
    [Parameter(Mandatory = $true)]
    [Diagnostics.Process]$Process
  )

  try {
    if (-not $Process.HasExited) {
      $Process.Kill()
      [void]$Process.WaitForExit(5000)
    }
  } catch {
    Write-Verbose "Could not stop process $($Process.Id) after startup failed: $($_.Exception.Message)"
  }
}

function Wait-KwikenBrowserStartup {
  param(
    [Parameter(Mandatory = $true)]
    [Diagnostics.Process]$Process,
    [ValidateRange(1, 300)]
    [int]$StartupTimeoutSeconds = 30,
    [ValidateRange(0, 10000)]
    [int]$StabilityMilliseconds = 1500
  )

  $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
  $windowReady = $false

  while ([DateTime]::UtcNow -lt $deadline) {
    if ($Process.HasExited) {
      throw "Kwiken exited before opening a visible window (exit code $($Process.ExitCode))."
    }

    $Process.Refresh()
    if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
      $windowReady = $true
      break
    }
    Start-Sleep -Milliseconds 100
  }

  if (-not $windowReady) {
    Stop-KwikenProcessAfterStartupFailure -Process $Process
    throw "Kwiken did not open a visible window within $StartupTimeoutSeconds seconds. The startup process was stopped."
  }

  $stabilityDeadline = [DateTime]::UtcNow.AddMilliseconds($StabilityMilliseconds)
  while ([DateTime]::UtcNow -lt $stabilityDeadline) {
    if ($Process.HasExited) {
      throw "Kwiken exited during startup (exit code $($Process.ExitCode))."
    }
    Start-Sleep -Milliseconds 100
  }
}
