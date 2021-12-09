#region Prerequisites
<#
Set-Alias mediainfo 'D:\Program Files\MediaInfo\CLI\MediaInfo.exe'
Set-Alias makemkvcon64 'D:\Program Files (x86)\MakeMKV\makemkvcon64.exe'
Set-Alias makemkvcon 'D:\Program Files (x86)\MakeMKV\makemkvcon.exe'
Set-Alias HandBrakeCLI 'D:\Program Files\Handbrake\HandBrakeCLI.exe'
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
.PARAMETER MaxLengthMins
Param 4
#>
function Invoke-MakeMkv {
    [cmdletbinding(SupportsShouldProcess=$true)]
    param(
        [parameter(Position=0,ValueFromPipeline=$true)]
        [string]$SourceDirectory = 'F:\',
        [string]$DestinationDirectory = 'S:\~rip\MakeMKV',
        [int]$MinLengthMins = 0,
        [int]$MaxLengthMins
    )

    $makeMkvArgs = '-r', '--decrypt', '--directio=true', '--cache=1024'
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
        [string]$DestinationDirectory = 'S:\~rip\Handbrake\~processed',
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
                $isFirstAudioTrackEnglish = $false
                for ($i = 1; $i -le $audioLangs.Count; $i++) {
                    $index = $i - 1
                    if ($audioLangs[$index]) {
                        if (Confirm-EnglishCode($audioLangs[$index])) {
                            if ($i -eq 1) { 
                                $isFirstAudioTrackEnglish = $true 
                            }
                            else {
                                $includeAudioTracks += $i
                            }
                            #break
                        }
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
                        if (Confirm-EnglishCode($subtitleLangs[$index])) {
                            $includeSubtitleTracks += $i
                            break
                        }
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
                    $args += "--encoder", "x264"    # use H.264 encoder
                    $args += "--quality", "19.0"    # video quality (lower is better)
                    $args += "--cfr"                # constant framerate
        
                ### Audio Options
                    if ($numAudio -gt 0) {
                        $args += "--audio", ($includeAudioTracks -join ',')             # audio tracks
                        $args += "--aencoder", "copy:ac3"   # AC3 passthru
                    }
        
                ### Picture Settings
                    $args += "--crop", "0:0:0:0"
                    $args += "--strict-anamorphic"
        
                ### Filters
                    $args += "--decomb=bob"
        
                ### Subtitle Options
                    if ($numSubtitle -gt 0) {
                        if ($firstAudioTrackIsEnglish) {
                            $args += "--subtitle", "scan,$($includeSubtitleTracks -join ',')" # forced subtitle scan if first track is english
                            $args += "--subtitle-burned", "scan"
                            $args += "--native-language", "eng"
                        }
                        else {
                            $args += "--subtitle", ($includeSubtitleTracks -join ',')
                        }
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

    # Use: makemkvcon [switches] Command [Parameters] 
        <#
        http://www.makemkv.com/developers/usage.txt\
        
        Commands:
        info <source>
            prints info about disc
        mkv <source> <title id> <destination folder>
            saves a single title to mkv file
        stream <source>
            starts streaming server
        backup <source> <destination folder>
            backs up disc to a hard drive

        Source specification:
        iso:<FileName>    - open iso image <FileName>
        file:<FolderName> - open files in folder <FolderName>
        disc:<DiscId>     - open disc with id <DiscId> (see list Command)
        dev:<DeviceName>  - open disc with OS device name <DeviceName>

        Switches:
        -r --robot        - turn on "robot" mode, see http://www.makemkv.com/developers
        #>

    # Syntax: HandBrakeCLI [options] -i <device> -o <file>
    ### General Handbrake Options------------------------------------------------
        <#
        -h, --help              Print help
        -u, --update            Check for updates and exit
        -v, --verbose {#}       Be verbose (optional argument: logging level)
        -Z. --preset <string>   Use a built-in preset. Capitalization matters, and
        if the preset name has spaces, surround it with
        double quotation marks
        -z, --preset-list       See a list of available built-in presets
        --no-dvdnav         Do not use dvdnav for reading DVDs
        --no-opencl             Disable use of OpenCL
        #>
    ### Source Options-----------------------------------------------------------
        <#
        -i, --input <string>    Set input device
        -t, --title <number>    Select a title to encode (0 to scan all titles only,
            default: 1)
        --min-duration      Set the minimum title duration (in seconds). Shorter
            titles will not be scanned (default: 10).
        --scan              Scan selected title only.
        --main-feature      Detect and select the main feature title.
        -c, --chapters <string> Select chapters (e.g. "1-3" for chapters
            1 to 3, or "3" for chapter 3 only,
            default: all chapters)
        --angle <number>    Select the video angle (DVD or Blu-ray only)
        --previews <#:B>    Select how many preview images are generated,
            and whether or not they're stored to disk (0 or 1).
            (default: 10:0)
        --start-at-preview {#}  Start encoding at a given preview.
        --start-at    {unit:#}  Start encoding at a given frame, duration (in seconds),
            or pts (on a 90kHz clock)
        --stop-at     {unit:#}  Stop encoding at a given frame, duration (in seconds),
            or pts (on a 90kHz clock)
        #>
    ### Destination Options------------------------------------------------------
        <#
        -o, --output <string>   Set output file name
        -f, --format <string>   Set output container format (av_mp4/av_mkv)
            (default: autodetected from file name)
        -m, --markers           Add chapter markers
        -O, --optimize          Optimize mp4 files for HTTP streaming ("fast start")
        -I, --ipod-atom         Mark mp4 files so 5.5G iPods will accept them
        -P, --use-opencl        Use OpenCL where applicable
        -U, --use-hwd           Use DXVA2 hardware decoding
        <#
    ### Video Options------------------------------------------------------------
        <#
        -e, --encoder <string>  Set video library encoder
            Options: x264/x265/mpeg4/mpeg2/VP8/theora
            (default: mpeg4)
        --encoder-preset    Adjust video encoding settings for a particular
        <string>          speed/efficiency tradeoff (encoder-specific)
        --encoder-preset-list   List supported --encoder-preset values for the
        <string>          specified video encoder
        --encoder-tune      Adjust video encoding settings for a particular
        <string>          type of souce or situation (encoder-specific)
        --encoder-tune-list     List supported --encoder-tune values for the
        <string>          specified video encoder
        -x, --encopts <string>  Specify advanced encoding options in the same
            style as mencoder (all encoders except theora):
            option1=value1:option2=value2
        --encoder-profile   Ensures compliance with the requested codec
        <string>          profile (encoder-specific)
        --encoder-profile-list  List supported --encoder-profile values for the
        <string>          specified video encoder
        --encoder-level     Ensures compliance with the requested codec
        <string>          level (encoder-specific)
        --encoder-level-list    List supported --encoder-level values for the
        <string>          specified video encoder
        -q, --quality <number>  Set video quality
        -b, --vb <kb/s>         Set video bitrate (default: 1000)
        -2, --two-pass          Use two-pass mode
        -T, --turbo             When using 2-pass use "turbo" options on the
            1st pass to improve speed (only works with x264)
        -r, --rate              Set video framerate (5/10/12/15/23.976/24/25/29.97/30/50/59.94/60)
            Be aware that not specifying a framerate lets
            HandBrake preserve a source's time stamps,
            potentially creating variable framerate video
        --vfr, --cfr, --pfr     Select variable, constant or peak-limited
            frame rate control. VFR preserves the source
            timing. CFR makes the output constant rate at
            the rate given by the -r flag (or the source's
            average rate if no -r is given). PFR doesn't
            allow the rate to go over the rate specified
            with the -r flag but won't change the source
            timing if it's below that rate.
            If none of these flags are given, the default
            is --cfr when -r is given and --vfr otherwise
        #>
    ### Audio Options-----------------------------------------------------------
        <#
        -a, --audio <string>    Select audio track(s), separated by commas
            ("none" for no audio, "1,2,3" for multiple
            tracks, default: first one).
            Multiple output tracks can be used for one input.
        -E, --aencoder <string> Audio encoder(s):
            av_aac
            fdk_aac
            fdk_haac
            copy:aac
            ac3
            copy:ac3
            copy:dts
            copy:dtshd
            mp3
            copy:mp3
            vorbis
            flac16
            flac24
            copy
            copy:* will passthrough the corresponding
            audio unmodified to the muxer if it is a
            supported passthrough audio type.
            Separated by commas for more than one audio track.
            Defaults:
            av_mp4   av_aac
            av_mkv   mp3
        --audio-copy-mask   Set audio codecs that are permitted when the
        <string>    "copy" audio encoder option is specified
            (aac/ac3/dts/dtshd/mp3, default: all).
            Separated by commas for multiple allowed options.
        --audio-fallback    Set audio codec to use when it is not possible
        <string>    to copy an audio track without re-encoding.
        -B, --ab <kb/s>         Set audio bitrate(s) (default: depends on the
            selected codec, mixdown and samplerate)
            Separated by commas for more than one audio track.
        -Q, --aq <quality>      Set audio quality metric (default: depends on the
            selected codec)
            Separated by commas for more than one audio track.
        -C, --ac <compression>  Set audio compression metric (default: depends on the
            selected codec)
            Separated by commas for more than one audio track.
        -6, --mixdown <string>  Format(s) for audio downmixing/upmixing:
            mono
            left_only
            right_only
            stereo
            dpl1
            dpl2
            5point1
            6point1
            7point1
            5_2_lfe
            Separated by commas for more than one audio track.
            Defaults:
            av_aac           up to dpl2
            fdk_aac          up to dpl2
            fdk_haac         up to dpl2
            ac3              up to 5point1
            mp3              up to dpl2
            vorbis           up to dpl2
            flac16           up to 7point1
            flac24           up to 7point1
        --normalize-mix     Normalize audio mix levels to prevent clipping.
        <string>     Separated by commas for more than one audio track.
            0 = Disable Normalization (default)
            1 = Enable Normalization
        -R, --arate             Set audio samplerate(s) (8/11.025/12/16/22.05/24/32/44.1/48 kHz)
            Separated by commas for more than one audio track.
        -D, --drc <float>       Apply extra dynamic range compression to the audio,
            making soft sounds louder. Range is 1.0 to 4.0
            (too loud), with 1.5 - 2.5 being a useful range.
            Separated by commas for more than one audio track.
        --gain <float>      Amplify or attenuate audio before encoding.  Does
            NOT work with audio passthru (copy). Values are in
            dB.  Negative values attenuate, positive values
            amplify. A 1 dB difference is barely audible.
        --adither <string>  Apply dithering to the audio before encoding.
            Separated by commas for more than one audio track.
            Only supported by some encoders (fdk_aac/fdk_haac/flac16).
            Options:
            auto (default)
            none
            rectangular
            triangular
            triangular_hp
            triangular_ns
        -A, --aname <string>    Audio track name(s),
            Separated by commas for more than one audio track.
        #>
    ### Picture Settings---------------------------------------------------------
        <#
        -w, --width  <number>   Set picture width
        -l, --height <number>   Set picture height
        --crop  <T:B:L:R>   Set cropping values (default: autocrop)
        --loose-crop  {#}   Always crop to a multiple of the modulus
            Specifies the maximum number of extra pixels
            which may be cropped (default: 15)
        -Y, --maxHeight   {#}   Set maximum height
        -X, --maxWidth    {#}   Set maximum width
        --strict-anamorphic     Store pixel aspect ratio in video stream
        --loose-anamorphic      Store pixel aspect ratio with specified width
        --custom-anamorphic     Store pixel aspect ratio in video stream and
            directly control all parameters.
        --display-width         Set the width to scale the actual pixels to
        <number>              at playback, for custom anamorphic.
        --keep-display-aspect   Preserve the source's display aspect ratio
            when using custom anamorphic
        --pixel-aspect          Set a custom pixel aspect for custom anamorphic
        <PARX:PARY>
            (--display-width and --pixel-aspect are mutually
            exclusive and the former will override the latter)
        --itu-par               Use wider, ITU pixel aspect values for loose and
            custom anamorphic, useful with underscanned sources
        --modulus               Set the number you want the scaled pixel dimensions
        <number>              to divide cleanly by. Does not affect strict
            anamorphic mode, which is always mod 2 (default: 16)
        -M, --color-matrix      Set the color space signaled by the output
            Values: 709, pal, ntsc, 601 (same as ntsc)
            (default: detected from source)
        #>
    ### Filters---------------------------------------------------------
        <#
        -d, --deinterlace       Unconditionally deinterlaces all frames
        <fast/slow/slower/bob> or omitted (default settings)
        or
        <YM:FD>           (default 0:-1)
        -5, --decomb            Selectively deinterlaces when it detects combing
        <fast/bob> or omitted (default settings)
        or
        <MO:ME:MT:ST:BT:BX:BY:MG:VA:LA:DI:ER:NO:MD:PP:FD>
        (default: 7:2:6:9:80:16:16:10:20:20:4:2:50:24:1:-1)
        -9, --detelecine        Detelecine (ivtc) video with pullup filter
            Note: this filter drops duplicate frames to
            restore the pre-telecine framerate, unless you
            specify a constant framerate (--rate 29.97)
        <L:R:T:B:SB:MP:FD> (default 1:1:4:4:0:0:-1)
        -8, --denoise           Denoise video with hqdn3d filter
        <ultralight/light/medium/strong> or omitted (default settings)
        or
        <SL:SCb:SCr:TL:TCb:TCr>
        (default: 4:3:3:6:4.5:4.5)
        --nlmeans               Denoise video with nlmeans filter
        <ultralight/light/medium/strong> or omitted
        or
        <SY:OTY:PSY:RY:FY:PY:Sb:OTb:PSb:Rb:Fb:Pb:Sr:OTr:PSr:Rr:Fr:Pr>
        (default 8:1:7:3:2:0)
        --nlmeans-tune          Tune nlmeans filter to content type
            Note: only works in conjunction with presets
            ultralight/light/medium/strong.
        <none/film/grain/highmotion/animation> or omitted (default none)
        -7, --deblock           Deblock video with pp7 filter
        <QP:M>            (default 5:2)
        --rotate     <mode> Rotate image or flip its axes.
            Modes: (can be combined)
            1 vertical flip
            2 horizontal flip
            4 rotate clockwise 90 degrees
            Default: 3 (vertical and horizontal flip)
        -g, --grayscale         Grayscale encoding
        #>
    ### Subtitle Options------------------------------------------------------------
        <#
        -s, --subtitle <string> Select subtitle track(s), separated by commas
            More than one output track can be used for one
            input.
            Example: "1,2,3" for multiple tracks.
            A special track name "scan" adds an extra 1st pass.
            This extra pass scans subtitles matching the
            language of the first audio or the language
            selected by --native-language.
            The one that's only used 10 percent of the time
            or less is selected. This should locate subtitles
            for short foreign language segments. Best used in
            conjunction with --subtitle-forced.
        -F, --subtitle-forced   Only display subtitles from the selected stream if
        <string>          the subtitle has the forced flag set. The values in
            "string" are indexes into the subtitle list
            specified with '--subtitle'.
            Separated by commas for more than one subtitle track.
            Example: "1,2,3" for multiple tracks.
            If "string" is omitted, the first track is forced.
        --subtitle-burned   "Burn" the selected subtitle into the video track
        <number>          If "number" is omitted, the first track is burned.
            "number" is an index into the subtitle list
            specified with '--subtitle'.
        --subtitle-default  Flag the selected subtitle as the default subtitle
        <number>          to be displayed upon playback.  Setting no default
            means no subtitle will be automatically displayed
            If "number" is omitted, the first track is default.
            "number" is an index into the subtitle list
            specified with '--subtitle'.
        -N, --native-language   Specifiy your language preference. When the first
        <string>          audio track does not match your native language then
            select the first subtitle that does. When used in
            conjunction with --native-dub the audio track is
            changed in preference to subtitles. Provide the
            language's iso639-2 code (fre, eng, spa, dut, et cetera)
        --native-dub        Used in conjunction with --native-language
            requests that if no audio tracks are selected the
            default selected audio track will be the first one
            that matches the --native-language. If there are no
            matching audio tracks then the first matching
            subtitle track is used instead.
        --srt-file <string> SubRip SRT filename(s), separated by commas.
        --srt-codeset       Character codeset(s) that the SRT file(s) are
        <string>          encoded in, separated by commas.
            Use 'iconv -l' for a list of valid
            codesets. If not specified, 'latin1' is assumed
        --srt-offset        Offset (in milliseconds) to apply to the SRT file(s),
        <string>          separated by commas. If not specified, zero is assumed.
            Offsets may be negative.
        --srt-lang <string> Language as an iso639-2 code fra, eng, spa et cetera)
            for the SRT file(s), separated by commas. If not specified,
            then 'und' is used.
        --srt-default       Flag the selected srt as the default subtitle
        <number>          to be displayed upon playback.  Setting no default
            means no subtitle will be automatically displayed
            If "number" is omitted, the first srt is default.
            "number" is an 1 based index into the srt-file list
        --srt-burn          "Burn" the selected srt subtitle into the video track
        <number>          If "number" is omitted, the first srt is burned.
            "number" is an 1 based index into the srt-file list
        #>
