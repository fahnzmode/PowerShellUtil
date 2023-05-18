#region Prerequisites
<#
Set-Alias mediainfo 'C:\Program Files\MediaInfo\CLI\MediaInfo.exe'
Set-Alias makemkvcon64 'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe'
Set-Alias makemkvcon 'C:\Program Files (x86)\MakeMKV\makemkvcon.exe'
Set-Alias HandBrakeCLI 'C:\Program Files\HandBrake\CLI\HandBrakeCLI.exe'
#>
#endregion

# C:\Program Files\WindowsPowerShell\Modules\{module name}\{module name}.psm1

<#
.SYNOPSIS
Synopsis
.DESCRIPTION
Description
.EXAMPLE
Example 1
.EXAMPLE
Example 2
.PARAMETER SourceDirectory
Param 1
.PARAMETER DestinationDirectory
Param 2
.PARAMETER MinLengthMins
Param 3
#>
function Invoke-MakeMkv {
    [cmdletbinding(SupportsShouldProcess=$true)]
    param(
        [parameter(Position=0,ValueFromPipeline=$true)]
        [string]$SourceDirectory = 'D:\',
        [string]$DestinationDirectory = 'M:\Video\_tmp\.rip\MakeMKV',
        [int]$MinLengthMins = 0
    )

    $makeMkvArgs = '--decrypt', '--directio=true', '--cache=1024'
    $makeMkvArgs += "--minlength=$($MinLengthMins * 60)"

    if ($SourceDirectory -match "^([A-Za-z]{1}:)\\?$") {
        Write-Host "Root drive path detected"
        $driveInfoRaw = & makemkvcon64 -r --cache=1 info disc:9999 | Select-String "DRV:.*\`"$($matches.1)\`"$"
        $driveInfo = $driveInfoRaw -split ','
        $driveIndex = $driveInfo[0] -replace 'DRV:', ''
        $volumeName = $driveInfo[5] -replace '"', ''
        Write-Host "Found drive index '$driveIndex'"
        Write-Host "Found volume name '$volumeName'"
        $destinationFolderName = $volumeName
        $sourceArg += "disc:$driveIndex"
    }
    else {
        $sourceArg += "file:$SourceDirectory"
        $destinationFolderName = $SourceDirectory.Name
    }

    $fullWorkingPath = (Join-Path $DestinationDirectory $destinationFolderName)
    if (Test-Path $fullWorkingPath) {
        $destinationFolderName = "$destinationFolderName $(Get-Date -Format 'yyyyMMdd_HHmmss')"
        $fullWorkingPath = (Join-Path $DestinationDirectory $destinationFolderName)
    }
    New-Item -Path $fullWorkingPath -ItemType Directory | Out-Null

    $makeMkvArgs += 'mkv', '--progress=stdout', $sourceArg, 'all', $fullWorkingPath
    Write-Host "[COMMAND] makemkvcon64 $makeMkvArgs" -ForegroundColor Green
    if ($PSCmdlet.ShouldProcess("$makeMkvArgs", "MakeMkvCon64")) {
        & makemkvcon64 $makeMkvArgs | Write-Host
    }

    Write-Output $fullWorkingPath
}

function Confirm-EnglishCode {
    param(
        [parameter(Mandatory=$true)]
        [string]$code
    )
    if ($code -in 'en', 'eng', 'en-us') {
        return $true
    }
    else {
        return $false
    }
}

function Invoke-Handbrake {
    [cmdletbinding(SupportsShouldProcess=$true)]
    param(
        [parameter(Position=0,ValueFromPipeline=$true)]
        [string]$SourceDirectory,
        [Parameter(Position=1)]
        [string]$DestinationDirectory = 'M:\Video\_tmp\.rip\Handbrake',
        [string[]]$AudioLang,
        [string[]]$SubtitleLang,
        [int]$MinLengthMins,
        [int]$MaxLengthMins
    )

    if (Test-Path $SourceDirectory) {
        $sourceDirectoryName = (Get-Item $SourceDirectory).Name
    }
    else {
        exit 1
    }
    # https://handbrake.fr/docs/en/latest/cli/cli-options.html
    # https://handbrake.fr/docs/en/latest/technical/official-presets.html
    $filesToProcess = @()
    Get-ChildItem $SourceDirectory -Filter *.mkv | 
        ForEach-Object {
            Write-Host "Inspecting '$_'"
            
            $doAdd = $true
            if ($MinLengthMins -or $MaxLengthMins) {
                $durationMs = (& mediainfo $_.FullName --Inform='General;%Duration%')
                $durationMinutes = [Math]::Round($durationMs / 1000 / 60, 2)

                if ($MinLengthMins -and $durationMinutes -lt $MinLengthMins) {
                    $doAdd = $false
                }
                if ($doAdd -and $MaxLengthMins -and $durationMinutes -gt $MinLengthMins) {
                    $doAdd = $false
                }    
                if (!$doAdd) {
                    Write-Host "Skipping file - $($durationMinutes)m outside of target range"
                }
            }
            
            if ($doAdd) {
                $numAudio = mediainfo --Inform='General;%AudioCount%' $_.FullName
                if (!$numAudio) { $numAudio = 0 }
                $audioLangs = (mediainfo --Inform='Audio;%Language%,' $_.FullName) -split ','
                Write-Host "Found $numAudio audio tracks - $audioLangs"
    
                $includeAudioTracks = @(1) # always include the first track (usually will be the original language on foreign films)
                #$isFirstAudioTrackEnglish = $false
                for ($i = 1; $i -le $audioLangs.Count; $i++) {
                    $index = $i - 1
                    if ($audioLangs[$index]) {
                        #if (Confirm-EnglishCode($audioLangs[$index])) {
                        #    if ($i -eq 1) { 
                        #        $isFirstAudioTrackEnglish = $true 
                        #    }
                        #    else {
                                $includeAudioTracks += $i
                        #    }
                            #break
                        #}
                    }
                }
    
                $numSubtitle = mediainfo --Inform='General;%TextCount%' $_.FullName
                if (!$numSubtitle) { $numSubtitle = 0 }
                $subtitleLangs = (mediainfo --Inform='Text;%Language%,' $_.FullName) -split ','
                Write-Host "Found $numSubtitle subtitle tracks - $subtitleLangs"
    
                $includeSubtitleTracks = @()
                for ($i = 1; $i -le $subtitleLangs.Count; $i++) {
                    $index = $i - 1
                    if ($subtitleLangs[$index]) {
                        #if (Confirm-EnglishCode($subtitleLangs[$index])) {
                            $includeSubtitleTracks += $i
                        #    break
                        #}
                    }
                }

                $fullDestinationDirectory = Join-Path $DestinationDirectory $sourceDirectoryName
                if (!(Test-Path $fullDestinationDirectory)) {
                    New-Item -Path $fullDestinationDirectory -ItemType Directory
                }
                $fullDestinationPath = Join-Path $fullDestinationDirectory $_.Name
        
                ### Source Options
                    $args = @()
                    #$args += "--verbose"
                    $args += "--input", $_.FullName        # source file
        
                ### Destination Options
                    $args += "--output", $fullDestinationPath # destination file
                    $args += "--format", "av_mkv"        # container file type
                    $args += "--markers"                 # add chapter markers
        
                ### Video Options
                    $args += "--encoder", "x265"    # use H.265 encoder
                    $args += "--quality", "24.0"    # video quality (lower is better but larger file size)
                    $args += "--cfr"                # constant framerate
        
                ### Audio Options
                    if ($numAudio -gt 0) {
                        $args += "--audio", ($includeAudioTracks -join ',')             # audio tracks
                        $args += "--aencoder", "ac3"
                    }
        
                ### Picture Settings
                    $args += "--crop", "0:0:0:0"
                    $args += "--loose-anamorphic"
        
                ### Filters
                    $args += "--decomb=bob"
        
                ### Subtitle Options
                    if ($numSubtitle -gt 0) {
                        # if ($firstAudioTrackIsEnglish) {
                        #     $args += "--subtitle", "scan,$($includeSubtitleTracks -join ',')" # forced subtitle scan if first track is english
                        #     $args += "--subtitle-burned", "scan"
                        #     $args += "--native-language", "eng"
                        # }
                        # else {
                            $args += "--subtitle", ($includeSubtitleTracks -join ',')
                        # }
                    }
                
                Write-Host "COMMAND: HandBrakeCLI $args" -ForegroundColor Green
                if ($PSCmdlet.ShouldProcess("$args", "HandBrakeCli")) {
                    & HandBrakeCLI $args
                }
            }
        }
    Write-Host "Found $($filesToProcess.Count) files to process"
}

Export-ModuleMember -Function Invoke-MakeMkv
Export-ModuleMember -Function Invoke-Handbrake
