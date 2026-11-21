#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
  Lets a Gale profile load the BepInEx plugins that Vortex deploys into the game folder.

.DESCRIPTION
  Gale starts the game with Doorstop pointed at the profile's BepInEx, so BepInEx loads
  plugins from <profile>\BepInEx\plugins and never looks at <game>\BepInEx\plugins, where
  Vortex deploys mods. BepInEx scans the plugins folder recursively, so a directory
  junction <profile>\BepInEx\plugins\_vortex -> <game>\BepInEx\plugins makes the mods
  managed by Vortex load when the game is started from Gale.

  Creating a junction needs no administrator rights. Run the script again with -Remove
  to delete the junction; the mods in the game folder stay untouched.

.PARAMETER ProfilePath
  Gale profile folder (Gale: File > Open profile folder).

.PARAMETER GamePath
  Game folder (Gale: File > Open game folder).

.PARAMETER LinkName
  Name of the junction inside the profile's BepInEx\plugins folder.

.PARAMETER Remove
  Delete the junction instead of creating it.

.EXAMPLE
  .\link-vortex-plugins.ps1
  Creates the junction for the default Gale profile of Casualties: Unknown.

.EXAMPLE
  .\link-vortex-plugins.ps1 -Remove
  Deletes the junction.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string] $ProfilePath = "$env:APPDATA\com.kesomannen.gale\casualties-unknown\profiles\Default",
  [string] $GamePath = "${env:ProgramFiles(x86)}\Steam\steamapps\common\Casualties Unknown",
  [string] $LinkName = '_vortex',
  [switch] $Remove
)

$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
  Returns the target of a directory junction or symbolic link, or $null for anything else.
#>
function Get-LinkTarget {
  param([Parameter(Mandatory)] [string] $Path)

  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $item) { return $null }
  if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }

  # Windows PowerShell 5.1 returns Target as an array, PowerShell 7 as a string.
  return @($item.Target)[0]
}

<#
.SYNOPSIS
  Deletes the junction itself, never the folder it points to.
#>
function Remove-Junction {
  param([Parameter(Mandatory)] [string] $Path)

  if (-not (Get-LinkTarget $Path)) {
    Write-Warning "No junction at '$Path', nothing to remove."
    return
  }

  # Directory.Delete without recursion removes only the reparse point.
  [IO.Directory]::Delete($Path, $false)
  Write-Host "Removed junction '$Path'."
}

$profilePlugins = Join-Path $ProfilePath 'BepInEx\plugins'
$gamePlugins = Join-Path $GamePath 'BepInEx\plugins'
$linkPath = Join-Path $profilePlugins $LinkName

if ($Remove) {
  if ($PSCmdlet.ShouldProcess($linkPath, 'Remove junction')) { Remove-Junction $linkPath }
  return
}

if (-not (Test-Path -LiteralPath (Join-Path $ProfilePath 'BepInEx\core') -PathType Container)) {
  throw "No BepInEx in the Gale profile '$ProfilePath'. Install BepInExPack in Gale first, or pass -ProfilePath."
}

if (-not (Test-Path -LiteralPath $GamePath -PathType Container)) {
  throw "Game folder '$GamePath' not found. Pass -GamePath (Gale: File > Open game folder)."
}

if (Test-Path -LiteralPath (Join-Path $GamePath 'BepInEx\core') -PathType Container) {
  Write-Warning ("Vortex seems to have deployed BepInEx itself into '$GamePath\BepInEx\core'. " +
    "Gale overwrites winhttp.dll on every start, so purge BepInEx in Vortex and keep only the mods.")
}

$existingTarget = Get-LinkTarget $linkPath
$resolvedGamePlugins = [IO.Path]::GetFullPath($gamePlugins).TrimEnd('\')

if ($existingTarget -and ([IO.Path]::GetFullPath($existingTarget).TrimEnd('\') -eq $resolvedGamePlugins)) {
  Write-Host "Junction already in place: '$linkPath' -> '$gamePlugins'."
  return
}

if ($existingTarget) {
  throw "'$linkPath' already points to '$existingTarget'. Run with -Remove first, or pick another -LinkName."
}

if (Test-Path -LiteralPath $linkPath) {
  throw "'$linkPath' exists and is a real folder or file, not a junction. Move it away first."
}

if (-not $PSCmdlet.ShouldProcess("$linkPath -> $gamePlugins", 'Create junction')) { return }

# Vortex deploys here; create the folder so the junction has a target before the first deployment.
New-Item -ItemType Directory -Force -Path $gamePlugins | Out-Null
New-Item -ItemType Junction -Path $linkPath -Target $gamePlugins | Out-Null

Write-Host "Created junction '$linkPath' -> '$gamePlugins'."
Write-Host 'Start the game from Gale and look for the Vortex mods in the game log (Gale: File > Open game log).'
