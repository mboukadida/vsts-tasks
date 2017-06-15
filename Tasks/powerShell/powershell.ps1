[CmdletBinding()]
param()

Trace-VstsEnteringInvocation $MyInvocation
try {
    Import-VstsLocStrings "$PSScriptRoot\task.json"

    # TODO MOVE ASSERT-VSTSAGENT TO THE TASK LIB AND LOC
    function Assert-VstsAgent {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [version]$Minimum)

        if ($Minimum -lt ([version]'2.104.1')) {
            Write-Error "Assert-Agent requires the parameter to be 2.104.1 or higher"
            return
        }

        $agent = Get-VstsTaskVariable -Name 'agent.version'
        if (!$agent -or (([version]$agent) -lt $Minimum)) {
            Write-Error "Agent version $Minimum or higher is required."
        }
    }

    # Get inputs.
    $input_apartment = Get-VstsInput -Name 'apartment' -Default 'Sta'
    $input_errorActionPreference = Get-VstsInput -Name 'errorActionPreference' -Default 'Stop'
    switch ($input_errorActionPreference.ToUpperInvariant()) {
        'STOP' { }
        'CONTINUE' { }
        'SILENTLYCONTINUE' { }
        default {
            Write-Error (Get-VstsLocString -Key 'PS_InvalidErrorActionPreference' -ArgumentList $input_errorActionPreference)
        }
    }
    $input_executionPolicy = Get-VstsInput -Name 'executionPolicy' -Default 'Unrestricted'
    $input_failOnStderr = Get-VstsInput -Name 'failOnStderr' -AsBool
    $input_ignoreExitCode = Get-VstsInput -Name 'ignoreExitCode' -AsBool
    $input_ignoreLASTEXITCODE = Get-VstsInput -Name 'ignoreLASTEXITCODE' -AsBool
    $input_script = Get-VstsInput -Name 'script'
    $input_workingDirectory = Get-VstsInput -Name 'workingDirectory' -Require
    Assert-VstsPath -LiteralPath $input_workingDirectory -PathType 'Container'

    # Generate the script contents.
    $contents = @()
    $contents += "`$ErrorActionPreference = '$input_errorActionPreference'"
    $contents += $input_script
    if (!$ignoreLASTEXITCODE) {
        $contents += 'if (!(Test-Path -LiteralPath variable:\LASTEXITCODE)) {'
        $contents += '    Write-Verbose ''Last exit code is not set.'''
        $contents += '} else {'
        $contents += '    Write-Verbose (''$LASTEXITCODE: {0}'' -f $LASTEXITCODE)'
        $contents += '    exit $LASTEXITCODE'
        $contents += '}'
    }

    # Write the script to disk.
    Assert-VstsAgent -Minimum '2.115.0'
    $tempDirectory = Get-VstsTaskVariable -Name 'agent.tempDirectory' -Require
    Assert-VstsPath -LiteralPath $tempDirectory -PathType 'Container'
    $filePath = [System.IO.Path]::Combine($tempDirectory, "$([System.Guid]::NewGuid()).ps1")
    $joinedContents = [System.String]::Join(
        ([System.Environment]::NewLine),
        $contents)
    $null = [System.IO.File]::WriteAllText(
        $filePath,
        $joinedContents,
        ([System.Text.Encoding]::UTF8))

    # Run the script.
    $powershellPath = (Get-Command -Name powershell.exe -CommandType Application).Path
    Assert-VstsPath -LiteralPath $powershellPath -PathType 'Leaf'
    $arguments = "-NoLogo -$input_apartment -NoProfile -NonInteractive -ExecutionPolicy $input_executionPolicy -File `"$filePath`""
    $splat = @{
        'FileName' = $powershellPath
        'Arguments' = $arguments
        'WorkingDirectory' = $workingDirectory
        'RequireExitCodeZero' = !$ignoreExitCode
    }
    if (!$input_failOnStderr) {
        Invoke-VstsTool @splat
    } else {
        $global:ErrorActionPreference = 'Continue'
        Invoke-VstsTool @splat 2>&1 |
            ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    Write-Host "$($_.Exception.Message)"
                } else {
                    Write-Host "$_"
                }
            }
    }
} finally {
    Trace-VstsLeavingInvocation $MyInvocation
}