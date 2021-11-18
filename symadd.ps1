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
    [ValidateSet("Public", "Private")][string]$PdbKind,
    [Parameter(Position=0, ValueFromRemainingArguments)][string[]]$PdbPaths
)

function Get-RepositoryInformation ($path) {
    if (-not (Test-Path $path)) {
        return $null
    }
    for ($topdir = $path; $topdir; $topdir = Split-Path -Parent $topdir) {
        if (Test-Path "$topdir/.git" -PathType Container) {
            break
        }
    }
    if (-not $topdir) {
        return $null
    }
    $topdir = "$(Resolve-Path $topdir)"
    $origin = git -C $topdir config --local remote.origin.url 2>$null
    $commit = git -C $topdir rev-parse HEAD 2>$null
    $tracked = @{}
    git -C $topdir ls-tree --full-tree --name-only -r HEAD 2>$null | ForEach-Object { $tracked[$_]++ }
    $raworigin = $origin
    if ($raworigin) {
        if ($raworigin.EndsWith(".git", [StringComparison]::OrdinalIgnoreCase)) {
            $raworigin = $raworigin.Substring(0, $raworigin.Length - 4)
        }
        if ($raworigin.StartsWith("https://github.com/", [StringComparison]::OrdinalIgnoreCase) -or `
            $raworigin.StartsWith("https://bitbucket.org/", [StringComparison]::OrdinalIgnoreCase)) {
            $raworigin += "/raw/"
        } elseif ($raworigin.StartsWith("https://gitlab.com/", [StringComparison]::OrdinalIgnoreCase)) {
            $raworigin += "/-/raw/"
        } else {
            $raworigin += "/raw/"
        }
    }
    return [PSCustomObject]@{
        TopDir = $topdir
        Origin = $origin
        Commit = $commit
        Tracked = $tracked
        RawOrigin = $raworigin
    }
}

function Get-CachedRepositoryInformation ($repos, $path) {
    for ($topdir = $path; $topdir; $topdir = Split-Path -Parent $topdir) {
        if ($repos.ContainsKey($topdir)) {
            return $repos[$topdir]
        }
    }
    $info = Get-RepositoryInformation $path
    if ($info) {
        $repos[$info.TopDir] = $info
    }
    return $info
}

$paths = @()
foreach ($path in $PdbPaths) {
    $paths += Get-ChildItem $path -Recurse -Include *.pdb | Select-Object -ExpandProperty FullName
}
$paths = @($paths | Select-Object -Unique)
if (-not $paths) {
    [Console]::Error.WriteLine("Cannot find any PDB files.")
    exit 1
}

if (-not $GitDir) {
    $GitDir = Split-Path -Parent $paths[0]
    if (-not (Test-Path $GitDir -PathType Container)) {
        $GitDir = "."
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

$repos = @{}
$info = Get-CachedRepositoryInformation $repos $GitDir
if (-not $info) {
    [Console]::Error.WriteLine("Cannot get repo at `"$GitDir`"")
    exit 1
}
if (-not $info.Origin -or -not $info.Commit) {
    [Console]::Error.WriteLine("Cannot get origin or commit from repo at `"$($info.TopDir)`"")
    exit 1
}

Write-Output "TopDir: $($info.TopDir)"
Write-Output "Origin: $($info.Origin)"
Write-Output "Commit: $($info.Commit)"
Write-Output "SymDir: $SymDir"
Write-Output ""

$temp = New-TemporaryFile
try {
    [System.IO.File]::WriteAllLines($temp, $paths)
    switch ($PdbKind) {
        "Public" {
            & $symstore add /f "@$temp" /s $SymDir /t $info.Origin /v $info.Commit /z pub
        }
        "Private" {
            & $symstore add /f "@$temp" /s $SymDir /t $info.Origin /v $info.Commit /z pri
        }
        default {
            & $symstore add /f "@$temp" /s $SymDir /t $info.Origin /v $info.Commit
        }
    }

    $id = Get-Content (Join-Path $SymDir "000Admin/lastid.txt")
    $xn = Get-Content (Join-Path $SymDir "000Admin/$id") | ConvertFrom-Csv -Header SymPath,OrigPath

    foreach ($path in $xn.SymPath) {
        $name = Split-Path -Parent $path
        $path = (Join-Path $SymDir "$path/$name")

        $text = ""
        $text += "SRCSRV: ini ------------------------------------------------`r`n"
        $text += "VERSION=2`r`n"
        $text += "SRCSRV: variables ------------------------------------------`r`n"
        $text += "SRCSRVTRG=%var2%`r`n"
        $text += "SRCSRV: source files ---------------------------------------`r`n"
        $sources = & $srctool -r $path 2> $null
        foreach ($source in $sources) {
            if ($source.StartsWith($path)) {
                continue
            }
            $cinfo = Get-CachedRepositoryInformation $repos $source
            if (-not $cinfo) {
                continue
            }
            $trim = $source.Substring($cinfo.TopDir.Length + 1).Replace("\", "/")
            if (-not $cinfo.Tracked.ContainsKey($trim)) {
                continue
            }
            $text += "$source*$($cinfo.RawOrigin)$($cinfo.Commit)/$trim`r`n"
        }
        $text += "SRCSRV: end ------------------------------------------------`r`n"

        [System.IO.File]::WriteAllText($temp, $text)
        & $pdbstr -w -p:$path -i:$temp -s:srcsrv
    }
} finally {
    $temp.Delete()
}
