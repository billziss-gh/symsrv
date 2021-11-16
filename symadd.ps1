# symadd.ps1
#
# Copyright 2021 Bill Zissimopoulos

# .SYNOPSIS
# Add PDB files to symbol repository.
#
# .DESCRIPTION
# This tool is used to add PDB files and associated source code information
# to a Git repository hosting service (such as GitHub). The information is
# organized in a manner to make it possible to use the hosting service as a
# debugging symbol and source server that is usable by Windows debugging
# tools.
#
# .NOTES
# MIT License; Copyright 2021 Bill Zissimopoulos
#
# .LINK
# https://github.com/billziss-gh/symsrv


param (
    [string]$GitDir,
    [string]$SymDir,
    [Parameter(Position=0, ValueFromRemainingArguments)][string[]]$PdbPaths
)

function OriginToRaw ($origin) {
    $result = "$origin"

    # GitHub rules
    if ($result.EndsWith(".git", [StringComparison]::OrdinalIgnoreCase)) {
        $result = $result.Substring(0, $result.Length - 4)
    }
    $result += "/raw/"

    return $result
}

if (-not $PdbPaths) {
    exit 1
}

if (-not $GitDir) {
    $GitDir = $PdbPaths[0]
    if (-not (Test-Path $GitDir -PathType Container)) {
        $GitDir = Split-Path -Parent $PdbPaths[0]
        if (-not $GitDir) {
            $GitDir = "."
        }
    }
}

if (-not $SymDir) {
    if (Test-Path (Join-Path $PSScriptRoot "sym") -PathType Container) {
        $SymDir = Join-Path $PSScriptRoot "sym"
    } elseif (Test-Path (Join-Path $PSScriptRoot "../sym") -PathType Container) {
        $SymDir = Join-Path $PSScriptRoot "../sym"
    } else {
        $SymDir = Join-Path $PSScriptRoot "sym"
    }
}

$KitRoot = try {
    Get-ItemPropertyValue `
        -Path "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots" `
        -Name "KitsRoot10"
} catch {
    [Console]::Error.WriteLine("Cannot determine Windows Kit installation path.")
    exit 1
}

$symstore = Join-Path $KitRoot "Debuggers/x64/symstore.exe"
$srctool = Join-Path $KitRoot "Debuggers/x64/srcsrv/srctool.exe"
$pdbstr = Join-Path $KitRoot "Debuggers/x64/srcsrv/pdbstr.exe"

$topdir = git -C $GitDir rev-parse --show-toplevel 2>$null
if (-not $topdir) {
    [Console]::Error.WriteLine("Cannot get repo at `"$GitDir`"")
    exit 1
}

$topdir = Resolve-Path $topdir
$origin = git -C $topdir config --local remote.origin.url 2>$null
$commit = git -C $topdir rev-parse HEAD 2>$null
if (-not $origin -or -not $commit) {
    [Console]::Error.WriteLine("Cannot get origin or commit from repo at `"$topdir`"")
    exit 1
}

$paths = @()
foreach ($path in $PdbPaths) {
    $paths += Get-ChildItem $path -Recurse -Include *.pdb | Select-Object -ExpandProperty FullName
}
$paths = $paths | Select-Object -Unique
if (-not $paths) {
    [Console]::Error.WriteLine("Cannot find any PDB files.")
    exit 1
}

$raworig = OriginToRaw $origin

$tracked = @{}
git -C $topdir ls-tree --full-tree --name-only -r HEAD 2>$null | ForEach-Object { $tracked[$_]++ }

Write-Output "GitDir: $topdir"
Write-Output "Origin: $origin"
Write-Output "Commit: $commit"
Write-Output "SymDir: $SymDir"
Write-Output ""

$temp = New-TemporaryFile
try {
    [System.IO.File]::WriteAllLines($temp, $paths)
    & $symstore add /f "@$temp" /s $SymDir /t $origin /v $commit

    $id = Get-Content (Join-Path $SymDir "000Admin/lastid.txt")
    $xn = Get-Content (Join-Path $SymDir "000Admin/$id") | ConvertFrom-Csv -Header SymPath,OrigPath

    foreach ($path in $xn.SymPath) {
        $name = Split-Path -Parent $path
        $path = (Join-Path $SymDir "$path/$name")

        $sources = & $srctool -r $path 2> $null | Where-Object {
            $_.StartsWith($topdir, [StringComparison]::OrdinalIgnoreCase) -and `
            $tracked.ContainsKey($_.Substring("$topdir".Length + 1).Replace("\", "/"))
        }

        $text = "VERSION=2`nSRCSRVTRG=$raworig$commit/%var2%`n"
        foreach ($source in $sources) {
            $trim = $source.Substring("$topdir".Length + 1).Replace("\", "/")
            $text += "$source*$trim`n"
        }

        [System.IO.File]::WriteAllText($temp, $text)
        & $pdbstr -w -p:$path -i:$temp -s:srcsrv
    }
} finally {
    $temp.Delete()
}
