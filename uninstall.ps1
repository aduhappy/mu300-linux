<#
.SYNOPSIS
    Remove MU300 Linux and return the device to stock Android (Windows version of uninstall.sh).

.DESCRIPTION
    Run with the device booted in rooted Android and connected over USB (adb). It makes slot a (Android) the boot
    slot in misc, copies boot_a over boot_b, erases the Linux filesystem in the unpartitioned eMMC region and removes
    the installer leftovers. boot_a, the GPT, userdata and every other partition stay untouched.
    Needs: adb and Python 3.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$T = '/data/local/tmp'

function Say($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Die($m) { Write-Host "`nERROR: $m" -ForegroundColor Red; exit 1 }
function Ask($question, $default) {
    $a = Read-Host "$question [$default]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default } else { return $a.Trim() }
}
function SuDo($cmd) { (& adb shell "su -c '$cmd'" 2>$null) -join "`n" -replace "`r", '' }
function SuDoToFile($cmd, $path) { & cmd.exe /c "adb exec-out ""su -c '$cmd'"" > ""$path""" | Out-Null }
$script:PyExe = $null
function Python { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$PyArgs)
    if (-not $script:PyExe) {
        foreach ($n in 'python', 'python3', 'py') {
            $c = Get-Command $n -ErrorAction SilentlyContinue
            if ($c) { $script:PyExe = $c.Source; break }
        }
        if (-not $script:PyExe) { Die 'Python 3 not found' }
    }
    & $script:PyExe @PyArgs
}
function Hex32 { (SuDo 'dd if=/dev/block/by-name/misc bs=1 skip=2048 count=32 2>/dev/null | od -An -tx1') -replace '\s', '' }

Say 'Checking host tools and device'
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { Die 'adb not found' }
if ((& adb get-state 2>$null) -notmatch 'device') { Die 'no adb device (boot Android, enable USB debugging)' }
if ((SuDo 'id -u') -ne '0') { Die 'su does not work on the device' }
$model = "$(SuDo 'getprop ro.product.model') / $(SuDo 'getprop ro.product.device')"
Write-Host "device: $model"
if ($model -notmatch 'MU300|F50|mu300') { Die 'this does not look like a ZTE F50/MU300' }
if ((SuDo 'getprop ro.boot.slot_suffix') -ne '_a') { Die 'Android must be running from slot a (boot Android first: mu300-next-boot android)' }

Say 'Looking for the Linux installation'
$parts = (SuDo 'e=0; for p in /sys/block/mmcblk0/mmcblk0p*; do x=$(( $(cat $p/start) + $(cat $p/size) )); [ $x -gt $e ] && e=$x; done; echo $e $(cat /sys/block/mmcblk0/size)').Split(' ')
if ($parts.Count -ne 2) { Die 'could not read the partition table from the device (is su granted? try again)' }
[int64]$lastEnd = $parts[0]; [int64]$disk = $parts[1]
[int64]$OFF = 0; [int64]$SIZE = 0
[int64]$start = [math]::Floor($lastEnd / 4096 + 1) * 4096 * 512
foreach ($cand in @($start, 27762098176)) {
    $m = (SuDo "dd if=/dev/block/mmcblk0 bs=1 skip=$($cand + 1080) count=2 2>/dev/null | od -An -tx1") -replace '\s', ''
    $l = (SuDo "dd if=/dev/block/mmcblk0 bs=1 skip=$($cand + 1144) count=16 2>/dev/null") -replace '\0', ''
    if ($m -eq '53ef' -and $l.Trim() -eq 'mu300root') {
        $blocks = [int64]((SuDo "dd if=/dev/block/mmcblk0 bs=1 skip=$($cand + 1028) count=4 2>/dev/null | od -An -tu4").Trim())
        $OFF = $cand; $SIZE = $blocks * 4096; break
    }
}
if ($OFF -gt 0) {
    if (($OFF / 512) -lt $lastEnd -or (($OFF + $SIZE) / 512) -gt ($disk - 34)) { Die 'the mu300root filesystem overlaps a partition, refusing to touch it' }
    if ($OFF % 1MB -ne 0) { Die "unexpected filesystem offset $OFF" }
    Write-Host "Linux filesystem: offset $OFF, $([int64]($SIZE / 1MB)) MiB"
} else {
    Write-Host 'no mu300root filesystem found (already erased?)'
}
$BC = Hex32

Say 'What should be removed?'
$wipe = Ask 'Erase the Linux filesystem: quick (headers only, space reusable) / full (zero-fill, takes minutes) / keep' 'quick'
if ($wipe -notin @('quick', 'full', 'keep')) { Die 'invalid choice' }
if ($OFF -eq 0) { $wipe = 'keep' }
Write-Host ''
Write-Host '  misc:     boot slot a (Android), Linux boot disabled'
Write-Host '  boot_b:   replaced with a copy of boot_a (stock Android boot image)'
Write-Host "  Linux:    $(if ($wipe -eq 'keep') { 'kept on the eMMC (not bootable)' } else { "$wipe erase of $([int64]($SIZE / 1MB)) MiB at offset $OFF" })"
Write-Host '  untouched: boot_a, GPT, userdata and all other partitions'
if ((Ask 'Type UNINSTALL to continue' 'no') -ne 'UNINSTALL') { Die 'cancelled' }

Say 'Making slot a the boot slot'
$miscTmp = [IO.Path]::GetTempFileName()
SuDoToFile 'dd if=/dev/block/by-name/misc bs=4096 count=1 2>/dev/null' $miscTmp
$py = @'
import struct, sys, zlib
head = open(sys.argv[1], "rb").read()
bc = bytearray(head[0x800:0x820])
if len(bc) != 32 or bc[4:8] != b"BCAB" or zlib.crc32(bytes(bc[:28])) != struct.unpack("<I", bc[28:])[0]:
    sys.exit("misc has no valid bootloader_control block")
bc[0:4] = b"_a\0\0"; bc[12] = 0x9f; bc[14] = 0x1e
bc[28:32] = struct.pack("<I", zlib.crc32(bytes(bc[:28])))
print(bc.hex())
'@
$pyFile = [IO.Path]::GetTempFileName() + '.py'
[IO.File]::WriteAllText($pyFile, $py)
$NEW = (Python $pyFile $miscTmp | Select-Object -Last 1).Trim()
Remove-Item $miscTmp, $pyFile -ErrorAction SilentlyContinue
if ($NEW.Length -ne 64) { Die 'cannot build the slot a boot control block' }
if ($BC -ne $NEW) {
    $bin = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllBytes($bin, ([byte[]] -split ($NEW -replace '..', '0x$& ')))
    & adb push $bin "$T/mu300-bc-a.bin" | Out-Null
    Remove-Item $bin
    SuDo "dd if=$T/mu300-bc-a.bin of=/dev/block/by-name/misc bs=1 seek=2048 conv=notrunc 2>/dev/null && sync && rm $T/mu300-bc-a.bin" | Out-Null
    if ((Hex32) -ne $NEW) { Die 'misc verify failed' }
    Write-Host 'slot a set'
} else {
    Write-Host 'already on slot a'
}

Say 'Restoring boot_b from boot_a'
$A = (SuDo 'sha256sum /dev/block/by-name/boot_a').Split(' ')[0]
SuDo 'dd if=/dev/block/by-name/boot_a of=/dev/block/by-name/boot_b bs=4M 2>/dev/null && sync' | Out-Null
if ((SuDo 'sha256sum /dev/block/by-name/boot_b').Split(' ')[0] -ne $A) { Die 'boot_b verify failed (misc already points to slot a, Android keeps booting)' }
Write-Host 'boot_b = boot_a'

if ($wipe -ne 'keep') {
    Say "Erasing the Linux filesystem ($wipe)"
    $busy = SuDo "for o in /sys/block/loop*/loop/offset; do [ ""`$(cat `$o 2>/dev/null)"" = $OFF ] && echo `${o%/loop/offset}; done"
    if ($busy) { Die "the Linux region is still attached ($busy); reboot Android and run again" }
    [int64]$skip = $OFF / 1MB; [int64]$mib = $SIZE / 1MB
    if ($wipe -eq 'quick') {
        SuDo "dd if=/dev/zero of=/dev/block/mmcblk0 bs=1048576 seek=$skip count=64 conv=notrunc 2>/dev/null; sync" | Out-Null
    } else {
        Write-Host "zero-filling $mib MiB, this takes several minutes"
        SuDo "dd if=/dev/zero of=/dev/block/mmcblk0 bs=1048576 seek=$skip count=$mib conv=notrunc 2>/dev/null; sync" | Out-Null
    }
    $m = (SuDo "dd if=/dev/block/mmcblk0 bs=1 skip=$($OFF + 1080) count=2 2>/dev/null | od -An -tx1") -replace '\s', ''
    if ($m -eq '53ef') { Die 'the filesystem signature is still there' }
    Write-Host 'erased'
}

SuDo "grep -q "" $T/mu300root "" /proc/mounts || rm -rf $T/mu300root; rm -f $T/mu300-* $T/android-install.sh $T/android-mount-mu300root.sh" | Out-Null
Say 'Done. The device boots stock Android; reboot it once to check.'
