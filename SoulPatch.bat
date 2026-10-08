@echo off
setlocal
set "SOUL_PATCHER_SELF=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$m='#'+'__SOUL_PS__'; $r=[IO.File]::ReadAllText($env:SOUL_PATCHER_SELF); $i=$r.IndexOf($m); if($i -lt 0){exit 90}; Invoke-Expression ($r.Substring($i+$m.Length))"
set "SOUL_RC=%ERRORLEVEL%"
if not "%SOUL_RC%"=="0" echo. ^& echo Soul patcher exited with code %SOUL_RC%.
pause
exit /b %SOUL_RC%
#__SOUL_PS__
$ErrorActionPreference = 'Stop'

# ============================================================
# Soul Public Runtime installer
# - TQ.exe: reversible Soul loader + existing Common-colour fix
# - Engine.dll: exact HekToTQ Missing Sounds Fix binary patch
# - Game.dll: exact reversible Rare-world-drop sound patch
#   Rare world drops use the existing Epic world-drop sound path.
#   Inventory Rare drops remain on the normal dropSound path.
#   Epic/Legendary behaviour remains vanilla.
# ============================================================

$VanillaTQHash     = 'F7B56CEFA4DE9C9AFFFD1CD7B7D9992572D819718785CC4C4DF5DAC061063063'
$VanillaGameHash   = '754907EACF552656945FF9EAF1763630E138506517E91B698AB28A0C3186AA86'
$RareGamePatchedHash = 'AFFF8F510AC3355FA264257F11E777B89C51288B8AB27EBA1E1E94601FD6DBD9'
$VanillaEngineHash = '0AEDBB1805B4A5616F74E34D4F609F392E2C2DD4561C64C118F4772AB4F694F6'
$SoundEngineHash   = 'D8A844F37A72DDC7BBAB01E1773D722DF56FCD4CBCFD57C7C65B2B6ED2158AAC'

$VanillaLength = 0x35F600
$SoulRawSize   = 0x2200
$SoulVA        = 0x36A000
$SoulVS        = 0x3000
$SoulEntryRVA  = 0x36C000
$OriginalEntryRVA = 0x0003D878
$OriginalImageSize = 0x0036A000
$PatchedImageSize  = 0x0036D000

# Existing Soul Common-colour bypass:
# vanilla: 0F 84 8B 00 00 00
# Soul:    0F 84 00 00 00 00
$CommonFixOffset = 0x109CB4
$CommonVanillaByte = 0x8B
$CommonPatchedByte = 0x00

# Exact HekToTQ Missing Sounds Fix locations in Engine.dll.
$SoundHookOffset = 0x142C60
$SoundCodeOffset = 0x2AAA9C

$SoundHookOriginalHex = '558BEC83E4F8'
$SoundHookPatchedHex  = 'E9377E160090'

$SoundRoutineHex = '56578BF9E8800000008BCFE8F473E9FF8BC8E82D85EAFF85C0746B0F1F40008B77388BCEE83B3DF7FF8BCEE8D440F7FF8BCEE8FD36F7FF6A008BCEE80433F7FF8B86140500008B3885FF743A0F1F40008B77348B7F3853E8000000005B8D9B641000008B1B85FF7E1C0F1F4000837E080174070F1F400056FFD381C6B002000083EF0175E85B5F5EC3558BEC83E4F8E93681E9FF'

# ============================================================
# Exact Rare-world-drop sound patch in Game.dll
#
# Verified against Game_RareDropSound_DIAG_EpicOnRare.dll.
# Exactly 83 bytes differ from the known vanilla Game.dll:
#   0x18E9E8 .. 0x18EA2F : 72 bytes
#   0x1B85B4 .. 0x1B85BE : 11 bytes
# ============================================================

$RareSoundDispatcherOffset = 0x18E9E8
$RareSoundDispatcherOriginalHex = ('CC' * 72)
$RareSoundDispatcherPatchedHex = '8B875404000083F8027505E9C79B020083F8037505E9BD9B020083F8047505E9CF9B0200E9EB9B020090909090909090909090909090909090909090909090909090909090909090'

$RareSoundHookOffset = 0x1B85B4
$RareSoundHookOriginalHex = '8B875404000083F803751C'
$RareSoundHookPatchedHex = 'E92F64FDFF909090909090'


function Hex-Bytes([byte[]]$bytes) { -join ($bytes | ForEach-Object { $_.ToString('X2') }) }

function Hex-ToBytes([string]$hex) {
    if(($hex.Length % 2) -ne 0) { throw 'Invalid hex string length.' }
    $a = New-Object byte[] ($hex.Length / 2)
    for($i=0; $i -lt $a.Length; $i++) {
        $a[$i] = [Convert]::ToByte($hex.Substring($i*2,2),16)
    }
    return $a
}

function Sha256-Bytes([byte[]]$bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (Hex-Bytes ($sha.ComputeHash($bytes))) } finally { $sha.Dispose() }
}

function File-Hash([string]$path) {
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Read-U16([byte[]]$b,[int]$o) { [BitConverter]::ToUInt16($b,$o) }
function Read-U32([byte[]]$b,[int]$o) { [BitConverter]::ToUInt32($b,$o) }

function Write-U16([byte[]]$b,[int]$o,[uint16]$v) {
    $x=[BitConverter]::GetBytes($v)
    [Array]::Copy($x,0,$b,$o,2)
}

function Write-U32([byte[]]$b,[int]$o,[uint32]$v) {
    $x=[BitConverter]::GetBytes($v)
    [Array]::Copy($x,0,$b,$o,4)
}

function Replace-ExistingFile([string]$source,[string]$destination) {
    if(!(Test-Path -LiteralPath $source)) { throw "Temporary replacement file does not exist: $source" }
    if(!(Test-Path -LiteralPath $destination)) { throw "Cannot replace missing destination file: $destination" }
    try {
        Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
        Remove-Item -LiteralPath $source -Force -ErrorAction Stop
    } catch {
        throw "Failed to replace '$destination' with the prepared file.`n$($_.Exception.Message)"
    }
}

function Loader-Bytes {
    $h='9C60E8000000005B81EB07C036008D833CC0360050FF93D0FA1E0085C0741689C68D8B45C036005156FF93CCFA1E0085C07402FFD0619DE93C18CDFF536F756C2E646C6C00536F756C496E697400'
    return Hex-ToBytes $h
}

$LargeAddressAwareFlag = 0x0020

function Set-LargeAddressAware([byte[]]$b) {
    if($b.Length -lt 0x40) { throw 'TQ.exe is too small to contain a valid PE header.' }
    if((Read-U16 $b 0) -ne 0x5A4D) { throw 'TQ.exe does not have a valid MZ header.' }
    $pe=[int](Read-U32 $b 0x3C)
    if($pe -lt 0 -or ($pe+24) -gt $b.Length -or (Read-U32 $b $pe) -ne 0x00004550) { throw 'TQ.exe does not have a valid PE header.' }
    $o=$pe+22
    [uint16]$c=Read-U16 $b $o
    if(($c -band $LargeAddressAwareFlag) -eq 0) {
        Write-U16 $b $o ([uint16]($c -bor $LargeAddressAwareFlag))
        return $true
    }
    return $false
}

function Test-LargeAddressAware([byte[]]$b) {
    if($b.Length -lt 0x40 -or (Read-U16 $b 0) -ne 0x5A4D) { return $false }
    $pe=[int](Read-U32 $b 0x3C)
    if($pe -lt 0 -or ($pe+24) -gt $b.Length -or (Read-U32 $b $pe) -ne 0x00004550) { return $false }
    return ((Read-U16 $b ($pe+22) -band $LargeAddressAwareFlag) -ne 0)
}

function Find-GameRoot([string]$scriptDir) {
    $candidates = @($scriptDir)
    $parent = Split-Path -Parent $scriptDir
    if($parent -and $parent -ne $scriptDir) { $candidates += $parent }

    foreach($c in $candidates) {
        if(
            (Test-Path -LiteralPath (Join-Path $c 'TQ.exe')) -and
            (Test-Path -LiteralPath (Join-Path $c 'Game.dll')) -and
            (Test-Path -LiteralPath (Join-Path $c 'Engine.dll'))
        ) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }

    throw 'Could not find TQ.exe, Game.dll and Engine.dll. Put this package in the Titan Quest folder or one folder directly beneath it.'
}

function Test-LoaderPatch([byte[]]$b) {
    if($b.Length -ne ($VanillaLength+$SoulRawSize)) { return $false }
    if((Read-U16 $b 0) -ne 0x5A4D) { return $false }

    $pe=[int](Read-U32 $b 0x3C)
    if((Read-U32 $b $pe) -ne 0x00004550) { return $false }

    if((Read-U16 $b ($pe+6)) -ne 6) { return $false }

    $opt=$pe+24
    if((Read-U32 $b ($opt+16)) -ne $SoulEntryRVA) { return $false }
    if((Read-U32 $b ($opt+56)) -ne $PatchedImageSize) { return $false }

    $optSize=[int](Read-U16 $b ($pe+20))
    $sh=$opt+$optSize+(5*40)

    $name=[Text.Encoding]::ASCII.GetString($b,$sh,8).Trim([char]0)
    if($name -ne '.soul') { return $false }

    if((Read-U32 $b ($sh+8)) -ne $SoulVS) { return $false }
    if((Read-U32 $b ($sh+12)) -ne $SoulVA) { return $false }
    if((Read-U32 $b ($sh+16)) -ne $SoulRawSize) { return $false }
    if((Read-U32 $b ($sh+20)) -ne $VanillaLength) { return $false }
    if((Read-U32 $b ($sh+36)) -ne ([Convert]::ToUInt32('E0000020',16))) { return $false }

    $stub=Loader-Bytes
    [byte[]]$ext=New-Object byte[] $SoulRawSize
    [Array]::Copy($stub,0,$ext,0x2000,$stub.Length)

    for($i=0;$i -lt $SoulRawSize;$i++) {
        if($b[$VanillaLength+$i] -ne $ext[$i]) { return $false }
    }

    # Reconstruct the original TQ header/body and normalize the known
    # Common-colour byte that Soul intentionally changes at 0x109CB4.
    [byte[]]$v=New-Object byte[] $VanillaLength
    [Array]::Copy($b,0,$v,0,$VanillaLength)

    Write-U16 $v ($pe+6) 5
    Write-U32 $v ($opt+16) $OriginalEntryRVA
    Write-U32 $v ($opt+56) $OriginalImageSize

    # Remove Large Address Aware before comparing against the exact vanilla hash.
    [uint16]$chars=Read-U16 $v ($pe+22)
    Write-U16 $v ($pe+22) ([uint16]($chars -band 0xFFDF))

    for($i=0;$i -lt 40;$i++) { $v[$sh+$i]=0 }

    # This is the only deliberate modification outside the Soul loader section.
    # Normalize it before comparing against the exact vanilla SHA256.
    $v[$CommonFixOffset] = $CommonVanillaByte

    if((Sha256-Bytes $v) -ne $VanillaTQHash) { return $false }

    return $true
}

function Test-EngineSoundPatch([byte[]]$b) {
    # Identity is the complete SHA256. Do not rely on a hard-coded file length.
    # The known HekToTQ Engine.dll is 0x39B400 bytes.
    return ((Sha256-Bytes $b) -eq $SoundEngineHash)
}

function Verify-Dependencies([string]$root) {
    $g=File-Hash (Join-Path $root 'Game.dll')

    if($g -ne $VanillaGameHash -and $g -ne $RareGamePatchedHash) {
        throw "Game.dll is not the supported vanilla build or the recognized Soul Rare-world-drop sound patch.`nDetected: $g`nExpected vanilla: $VanillaGameHash`nExpected patched: $RareGamePatchedHash"
    }
}

function Backup-Vanilla([string]$source,[string]$backup,[string]$expectedHash,[string]$label) {
    $dir=Split-Path -Parent $backup
    if(!(Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    if(Test-Path -LiteralPath $backup) {
        if((File-Hash $backup) -ne $expectedHash) {
            throw "Existing Soul_Backup\$(Split-Path -Leaf $backup) is not the expected vanilla $label. Refusing to overwrite it."
        }
    } else {
        Copy-Item -LiteralPath $source -Destination $backup
    }
}

function Install-GameRareSound([string]$root) {
    $gamePath=Join-Path $root 'Game.dll'
    [byte[]]$g=[IO.File]::ReadAllBytes($gamePath)
    $gh=Sha256-Bytes $g

    if($gh -eq $RareGamePatchedHash) {
        Write-Host '[OK] Game.dll Rare-world-drop sound patch is already installed.' -ForegroundColor Green
        return
    }

    if($gh -ne $VanillaGameHash) {
        throw "Game.dll is not the supported vanilla build and is not the recognized Soul patch.`nDetected: $gh`nExpected vanilla: $VanillaGameHash`nExpected patched: $RareGamePatchedHash"
    }

    $backup=Join-Path $root 'Soul_Backup\Game.dll.vanilla'
    Backup-Vanilla $gamePath $backup $VanillaGameHash 'Game.dll'

    $dispatcherOriginal=Hex-ToBytes $RareSoundDispatcherOriginalHex
    $dispatcherPatched=Hex-ToBytes $RareSoundDispatcherPatchedHex
    $hookOriginal=Hex-ToBytes $RareSoundHookOriginalHex
    $hookPatched=Hex-ToBytes $RareSoundHookPatchedHex

    if($dispatcherOriginal.Length -ne 72) { throw "Internal Game.dll dispatcher length error: $($dispatcherOriginal.Length) bytes." }
    if($dispatcherPatched.Length -ne 72) { throw "Internal Game.dll patched dispatcher length error: $($dispatcherPatched.Length) bytes." }
    if($hookOriginal.Length -ne 11) { throw "Internal Game.dll hook length error: $($hookOriginal.Length) bytes." }
    if($hookPatched.Length -ne 11) { throw "Internal Game.dll patched hook length error: $($hookPatched.Length) bytes." }

    for($i=0;$i -lt $dispatcherOriginal.Length;$i++) {
        if($g[$RareSoundDispatcherOffset+$i] -ne $dispatcherOriginal[$i]) {
            throw 'Game.dll dispatcher site does not contain the expected vanilla bytes. Nothing was written.'
        }
    }

    for($i=0;$i -lt $hookOriginal.Length;$i++) {
        if($g[$RareSoundHookOffset+$i] -ne $hookOriginal[$i]) {
            throw 'Game.dll Rare-world-drop hook site does not contain the expected vanilla bytes. Nothing was written.'
        }
    }

    [Array]::Copy($dispatcherPatched,0,$g,$RareSoundDispatcherOffset,$dispatcherPatched.Length)
    [Array]::Copy($hookPatched,0,$g,$RareSoundHookOffset,$hookPatched.Length)

    $newHash=Sha256-Bytes $g
    if($newHash -ne $RareGamePatchedHash) {
        throw "Internal verification failed: constructed Game.dll does not exactly match the verified Rare-world-drop sound patch.`nCalculated: $newHash`nExpected: $RareGamePatchedHash"
    }

    $tmp=$gamePath+'.soul_tmp'
    [IO.File]::WriteAllBytes($tmp,$g)
    Replace-ExistingFile $tmp $gamePath

    $finalHash=File-Hash $gamePath
    if($finalHash -ne $RareGamePatchedHash) {
        throw "Game.dll was written, but final verification failed.`nDetected: $finalHash`nExpected: $RareGamePatchedHash"
    }

    Write-Host '[OK] Applied the exact reversible Rare-world-drop sound patch to Game.dll.' -ForegroundColor Green
    Write-Host "     Game SHA256: $finalHash"
}

function Uninstall-GameRareSound([string]$root) {
    $gamePath=Join-Path $root 'Game.dll'
    [byte[]]$cur=[IO.File]::ReadAllBytes($gamePath)
    $hash=Sha256-Bytes $cur

    if($hash -eq $VanillaGameHash) {
        Write-Host '[OK] Game.dll is already vanilla.' -ForegroundColor Green
        return
    }

    if($hash -ne $RareGamePatchedHash) {
        throw "Game.dll does not match the recognized Soul Rare-world-drop sound patch. Refusing to alter an unknown Game.dll.`nDetected: $hash`nExpected: $RareGamePatchedHash"
    }

    $backup=Join-Path $root 'Soul_Backup\Game.dll.vanilla'

    if((Test-Path -LiteralPath $backup) -and (File-Hash $backup) -eq $VanillaGameHash) {
        Copy-Item -LiteralPath $backup -Destination $gamePath -Force
        $restoredHash=File-Hash $gamePath
        if($restoredHash -ne $VanillaGameHash) {
            throw "Game.dll backup restoration completed, but the resulting file does not match the vanilla hash.`nDetected: $restoredHash`nExpected: $VanillaGameHash"
        }
        Write-Host '[OK] Restored the verified vanilla Game.dll backup.' -ForegroundColor Green
        return
    }

    # Deterministic fallback. The current file is known to be the exact
    # recognized patched binary, so reversing these 83 bytes reconstructs
    # the known vanilla binary. Verify the complete hash before writing.
    $dispatcherOriginal=Hex-ToBytes $RareSoundDispatcherOriginalHex
    $hookOriginal=Hex-ToBytes $RareSoundHookOriginalHex
    [Array]::Copy($dispatcherOriginal,0,$cur,$RareSoundDispatcherOffset,$dispatcherOriginal.Length)
    [Array]::Copy($hookOriginal,0,$cur,$RareSoundHookOffset,$hookOriginal.Length)

    $rehash=Sha256-Bytes $cur
    if($rehash -ne $VanillaGameHash) {
        throw "Deterministic Game.dll uninstall did not reconstruct the exact vanilla hash. Nothing was written.`nCalculated: $rehash`nExpected: $VanillaGameHash"
    }

    $tmp=$gamePath+'.soul_tmp'
    [IO.File]::WriteAllBytes($tmp,$cur)
    Replace-ExistingFile $tmp $gamePath

    $restoredHash=File-Hash $gamePath
    if($restoredHash -ne $VanillaGameHash) {
        throw "Game.dll was reconstructed but final verification failed.`nDetected: $restoredHash`nExpected: $VanillaGameHash"
    }

    Write-Host '[OK] Reconstructed and restored the exact vanilla Game.dll.' -ForegroundColor Green
}

function Install-TQ([string]$root,[string]$scriptDir) {
    $srcDll=Join-Path $scriptDir 'Soul.dll'
    $srcCore=Join-Path $scriptDir 'SoulCore.dll'

    if(!(Test-Path -LiteralPath $srcDll)) { throw 'Soul.dll is missing from the patcher package.' }
    if(!(Test-Path -LiteralPath $srcCore)) { throw 'SoulCore.dll is missing from the patcher package.' }

    $tqPath=Join-Path $root 'TQ.exe'
    [byte[]]$old=[IO.File]::ReadAllBytes($tqPath)
    $hash=Sha256-Bytes $old

    if(Test-LoaderPatch $old) {
        Write-Host '[OK] Soul loader is already installed and the Common-colour fix is recognized.' -ForegroundColor Green

        # Repair the known Common-colour byte if an otherwise valid Soul loader
        # somehow lost that one-byte feature.
        $changed=$false
        if($old[$CommonFixOffset] -ne $CommonPatchedByte) {
            $old[$CommonFixOffset]=$CommonPatchedByte
            $changed=$true
            Write-Host '[OK] Restored the existing Soul Common-colour byte fix.' -ForegroundColor Green
        }
        if(!(Test-LargeAddressAware $old)) {
            Set-LargeAddressAware $old | Out-Null
            $changed=$true
            Write-Host '[OK] Enabled Large Address Aware (4GB support).' -ForegroundColor Green
        }
        if($changed) {
            $tmp=$tqPath+'.soul_tmp'
            [IO.File]::WriteAllBytes($tmp,$old)
            Replace-ExistingFile $tmp $tqPath
        }
    }
    elseif($hash -eq $VanillaTQHash) {
        $backup=Join-Path $root 'Soul_Backup\TQ.exe.vanilla'
        Backup-Vanilla $tqPath $backup $VanillaTQHash 'TQ.exe'

        [byte[]]$b=New-Object byte[] ($VanillaLength+$SoulRawSize)
        [Array]::Copy($old,0,$b,0,$old.Length)

        $pe=[int](Read-U32 $b 0x3C)
        $opt=$pe+24
        $optSize=[int](Read-U16 $b ($pe+20))
        $sh=$opt+$optSize+(5*40)

        Write-U16 $b ($pe+6) 6
        Write-U32 $b ($opt+16) $SoulEntryRVA
        Write-U32 $b ($opt+56) $PatchedImageSize

        for($i=0;$i -lt 40;$i++) { $b[$sh+$i]=0 }

        $name=[Text.Encoding]::ASCII.GetBytes('.soul')
        [Array]::Copy($name,0,$b,$sh,$name.Length)

        Write-U32 $b ($sh+8) $SoulVS
        Write-U32 $b ($sh+12) $SoulVA
        Write-U32 $b ($sh+16) $SoulRawSize
        Write-U32 $b ($sh+20) $VanillaLength
        Write-U32 $b ($sh+36) ([Convert]::ToUInt32('E0000020',16))

        $stub=Loader-Bytes
        [Array]::Copy($stub,0,$b,$VanillaLength+0x2000,$stub.Length)

        if(!(Test-LoaderPatch $b)) {
            throw 'Internal verification failed while constructing the Soul loader patch.'
        }

        # Existing Soul Feature: Common item-colour bypass.
        $b[$CommonFixOffset]=$CommonPatchedByte

        if(!(Test-LoaderPatch $b)) {
            throw 'Internal verification failed after applying the Common-colour fix.'
        }

        Set-LargeAddressAware $b | Out-Null
        if(!(Test-LargeAddressAware $b)) {
            throw 'Internal verification failed after enabling Large Address Aware.'
        }

        $tmp=$tqPath+'.soul_tmp'
        [IO.File]::WriteAllBytes($tmp,$b)
        Replace-ExistingFile $tmp $tqPath

        [byte[]]$finalTQ=[IO.File]::ReadAllBytes($tqPath)
        if(!(Test-LoaderPatch $finalTQ) -or !(Test-LargeAddressAware $finalTQ)) {
            throw 'TQ.exe was written, but final Soul/LAA verification failed.'
        }

        Write-Host '[OK] Patched TQ.exe with the reversible Soul.dll loader + Common-colour fix + Large Address Aware.' -ForegroundColor Green
    }
    else {
        throw "TQ.exe is modified or the wrong version.`nDetected: $hash`nExpected vanilla: $VanillaTQHash"
    }

    $dstDll=Join-Path $root 'Soul.dll'
    if((Resolve-Path -LiteralPath $srcDll).Path -ne ([IO.Path]::GetFullPath($dstDll))) {
        Copy-Item -LiteralPath $srcDll -Destination $dstDll -Force
    }

    $dstCore=Join-Path $root 'SoulCore.dll'
    if((Resolve-Path -LiteralPath $srcCore).Path -ne ([IO.Path]::GetFullPath($dstCore))) {
        Copy-Item -LiteralPath $srcCore -Destination $dstCore -Force
    }

    $srcCfg=Join-Path $scriptDir 'SoulColours.cfg'
    $dstCfg=Join-Path $root 'SoulColours.cfg'
    if((Test-Path -LiteralPath $srcCfg) -and !(Test-Path -LiteralPath $dstCfg)) {
        Copy-Item -LiteralPath $srcCfg -Destination $dstCfg
    }
}

function Install-SoundFix([string]$root) {
    $enginePath=Join-Path $root 'Engine.dll'
    [byte[]]$e=[IO.File]::ReadAllBytes($enginePath)
    $eh=Sha256-Bytes $e

    if(Test-EngineSoundPatch $e) {
        Write-Host '[OK] HekToTQ Missing Sounds Fix is already installed in Engine.dll.' -ForegroundColor Green
        return
    }

    if($eh -ne $VanillaEngineHash) {
        throw "Engine.dll is not the supported vanilla build and is not the recognized Hek sound patch.`nDetected: $eh`nExpected vanilla: $VanillaEngineHash`nExpected Hek patch: $SoundEngineHash"
    }

    $backup=Join-Path $root 'Soul_Backup\Engine.dll.vanilla'
    Backup-Vanilla $enginePath $backup $VanillaEngineHash 'Engine.dll'

    $hookOriginal=Hex-ToBytes $SoundHookOriginalHex
    $hookPatched=Hex-ToBytes $SoundHookPatchedHex
    $routine=Hex-ToBytes $SoundRoutineHex

    for($i=0;$i -lt $hookOriginal.Length;$i++) {
        if($e[$SoundHookOffset+$i] -ne $hookOriginal[$i]) {
            throw 'Engine.dll hook site does not contain the expected vanilla bytes. Nothing was written.'
        }
    }

    if($routine.Length -ne 148) {
        throw "Internal sound routine length error: $($routine.Length) bytes."
    }

    # Apply exactly the two changed regions used by HekToTQ:
    # 6-byte JMP/NOP at 0x142C60 and 148-byte routine at 0x2AAA9C.
    [Array]::Copy($hookPatched,0,$e,$SoundHookOffset,$hookPatched.Length)
    [Array]::Copy($routine,0,$e,$SoundCodeOffset,$routine.Length)

    $newHash=Sha256-Bytes $e
    if($newHash -ne $SoundEngineHash) {
        throw "Internal verification failed: constructed Engine.dll does not exactly match HekToTQ's sound-fix binary.`nCalculated: $newHash`nExpected: $SoundEngineHash"
    }

    $tmp=$enginePath+'.soul_tmp'
    [IO.File]::WriteAllBytes($tmp,$e)
    Replace-ExistingFile $tmp $enginePath

    Write-Host '[OK] Applied the exact HekToTQ Missing Sounds Fix to Engine.dll.' -ForegroundColor Green
    Write-Host "     Engine SHA256: $newHash"
}

function Uninstall-TQ([string]$root) {
    $tqPath=Join-Path $root 'TQ.exe'
    [byte[]]$cur=[IO.File]::ReadAllBytes($tqPath)
    $hash=Sha256-Bytes $cur

    if($hash -eq $VanillaTQHash) {
        Write-Host '[OK] TQ.exe is already vanilla.' -ForegroundColor Green
        return
    }

    if(!(Test-LoaderPatch $cur)) {
        throw 'TQ.exe does not match the recognized Soul loader (including its Common-colour fix). Refusing to alter an unknown executable.'
    }

    $backup=Join-Path $root 'Soul_Backup\TQ.exe.vanilla'

    if((Test-Path -LiteralPath $backup) -and (File-Hash $backup) -eq $VanillaTQHash) {
        Copy-Item -LiteralPath $backup -Destination $tqPath -Force
        Write-Host '[OK] Restored the verified vanilla TQ.exe backup.' -ForegroundColor Green
        return
    }

    [byte[]]$b=New-Object byte[] $VanillaLength
    [Array]::Copy($cur,0,$b,0,$VanillaLength)

    $pe=[int](Read-U32 $b 0x3C)
    $opt=$pe+24
    $optSize=[int](Read-U16 $b ($pe+20))
    $sh=$opt+$optSize+(5*40)

    Write-U16 $b ($pe+6) 5
    Write-U32 $b ($opt+16) $OriginalEntryRVA
    Write-U32 $b ($opt+56) $OriginalImageSize
    [uint16]$chars=Read-U16 $b ($pe+22)
    Write-U16 $b ($pe+22) ([uint16]($chars -band 0xFFDF))
    for($i=0;$i -lt 40;$i++) { $b[$sh+$i]=0 }

    # Remove the known Common-colour modification as part of deterministic uninstall.
    $b[$CommonFixOffset]=$CommonVanillaByte

    $rehash=Sha256-Bytes $b
    if($rehash -ne $VanillaTQHash) {
        throw "Deterministic TQ uninstall did not reconstruct the exact vanilla hash. Nothing was written.`nCalculated: $rehash"
    }

    $tmp=$tqPath+'.soul_tmp'
    [IO.File]::WriteAllBytes($tmp,$b)
    Replace-ExistingFile $tmp $tqPath

    Write-Host '[OK] Reconstructed and restored the exact vanilla TQ.exe.' -ForegroundColor Green
}

function Uninstall-SoundFix([string]$root) {
    $enginePath=Join-Path $root 'Engine.dll'
    [byte[]]$cur=[IO.File]::ReadAllBytes($enginePath)
    $hash=Sha256-Bytes $cur

    if($hash -eq $VanillaEngineHash) {
        Write-Host '[OK] Engine.dll is already vanilla.' -ForegroundColor Green
        return
    }

    if(!(Test-EngineSoundPatch $cur)) {
        throw 'Engine.dll does not match the recognized HekToTQ sound patch. Refusing to alter an unknown Engine.dll.'
    }

    $backup=Join-Path $root 'Soul_Backup\Engine.dll.vanilla'

    if((Test-Path -LiteralPath $backup) -and (File-Hash $backup) -eq $VanillaEngineHash) {
        Copy-Item -LiteralPath $backup -Destination $enginePath -Force
        Write-Host '[OK] Restored the verified vanilla Engine.dll backup.' -ForegroundColor Green
        return
    }

    # Deterministic fallback: reverse the exact 6-byte hook and zero the
    # 148-byte routine. Verify the complete vanilla SHA256 before writing.
    [byte[]]$b=New-Object byte[] $cur.Length
    [Array]::Copy($cur,0,$b,0,$cur.Length)

    $hookOriginal=Hex-ToBytes $SoundHookOriginalHex
    [Array]::Copy($hookOriginal,0,$b,$SoundHookOffset,$hookOriginal.Length)

    for($i=0;$i -lt 148;$i++) { $b[$SoundCodeOffset+$i]=0 }

    $rehash=Sha256-Bytes $b
    if($rehash -ne $VanillaEngineHash) {
        throw "Deterministic Engine.dll uninstall did not reconstruct the exact vanilla hash. Nothing was written.`nCalculated: $rehash"
    }

    $tmp=$enginePath+'.soul_tmp'
    [IO.File]::WriteAllBytes($tmp,$b)
    Replace-ExistingFile $tmp $enginePath

    Write-Host '[OK] Reconstructed and restored the exact vanilla Engine.dll.' -ForegroundColor Green
}

function Verify-Soul([string]$root) {
    $tqPath=Join-Path $root 'TQ.exe'
    $g=Join-Path $root 'Game.dll'
    $e=Join-Path $root 'Engine.dll'

    [byte[]]$tb=[IO.File]::ReadAllBytes($tqPath)
    $th=Sha256-Bytes $tb

    Write-Host "TQ.exe     : $th"
    if($th -eq $VanillaTQHash) {
        Write-Host '  State: vanilla' -ForegroundColor Cyan
    } elseif(Test-LoaderPatch $tb) {
        Write-Host ($(if(Test-LargeAddressAware $tb){'  State: Soul loader + Common-colour fix + Large Address Aware installed'}else{'  State: Soul loader + Common-colour fix installed (Large Address Aware NOT enabled)'})) -ForegroundColor Green
    } else {
        Write-Host '  State: unknown/modified' -ForegroundColor Red
    }

    $gh=File-Hash $g
    Write-Host "Game.dll   : $gh"
    if($gh -eq $VanillaGameHash) {
        Write-Host '  State: supported vanilla' -ForegroundColor Cyan
    } elseif($gh -eq $RareGamePatchedHash) {
        Write-Host '  State: Soul Rare-world-drop sound patch installed' -ForegroundColor Green
    } else {
        Write-Host '  State: unsupported/modified' -ForegroundColor Red
    }

    $eh=File-Hash $e
    Write-Host "Engine.dll : $eh"
    if($eh -eq $VanillaEngineHash) {
        Write-Host '  State: vanilla' -ForegroundColor Cyan
    } elseif($eh -eq $SoundEngineHash) {
        Write-Host '  State: HekToTQ Missing Sounds Fix installed' -ForegroundColor Green
    } else {
        Write-Host '  State: unsupported/modified' -ForegroundColor Red
    }

    Write-Host ('Soul.dll    : '+$(if(Test-Path -LiteralPath (Join-Path $root 'Soul.dll')){'present'}else{'missing'}))
    Write-Host ('SoulCore.dll: '+$(if(Test-Path -LiteralPath (Join-Path $root 'SoulCore.dll')){'present'}else{'missing'}))
}

try {
    $self=$env:SOUL_PATCHER_SELF
    $scriptDir=Split-Path -Parent $self
    $root=Find-GameRoot $scriptDir

    if(Get-Process -Name 'TQ' -ErrorAction SilentlyContinue) {
        throw 'Titan Quest is running. Close the game before installing or uninstalling Soul.'
    }

    Write-Host '==================================================='
    Write-Host ' Soul Public Runtime - Reversible Installer'
    Write-Host '==================================================='
    Write-Host "Game folder: $root"
    Write-Host 'TQ.exe    : Soul loader + existing Common-colour fix'
    Write-Host 'Engine.dll: exact HekToTQ Missing Sounds Fix'
    Write-Host 'Game.dll  : exact reversible Rare-world-drop sound patch'
    Write-Host ''

    Write-Host '[1] Install / repair Soul + sound fix'
    Write-Host '[2] Uninstall Soul + sound fix'
    Write-Host '[3] Verify files'
    Write-Host '[4] Exit'

    $choice=Read-Host 'Choose'

    switch($choice) {
        '1' {
            Verify-Dependencies $root
            Install-TQ $root $scriptDir
            Install-SoundFix $root
            Install-GameRareSound $root
            Write-Host ''
            Write-Host '[DONE] Soul loader, Game Rare-world-drop sound patch and Engine sound fix are installed.' -ForegroundColor Green
        }
        '2' {
            Uninstall-GameRareSound $root
            Uninstall-SoundFix $root
            Uninstall-TQ $root
            Write-Host ''
            Write-Host '[DONE] TQ.exe, Game.dll and Engine.dll are restored to their verified vanilla states.' -ForegroundColor Green
        }
        '3' {
            Verify-Soul $root
        }
        '4' {
            exit 0
        }
        default {
            throw 'Invalid selection.'
        }
    }

    exit 0
}
catch {
    Write-Host ''
    Write-Host ('[ERROR] '+$_.Exception.Message) -ForegroundColor Red
    exit 1
}
