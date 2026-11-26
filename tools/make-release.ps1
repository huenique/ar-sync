# make-release.ps1 - build a release of Aronium Sync and publish it on GitHub.
# Clients pick up only PUBLISHED releases (see "Releasing an update" in README.md).
#
#   1. Bump VERSION (e.g. v1.1.0) and commit it on master.
#   2. powershell -ExecutionPolicy Bypass -File tools\make-release.ps1 -NoUpload   # build and check only
#   3. powershell -ExecutionPolicy Bypass -File tools\make-release.ps1             # tag, push tag, gh release create
#
# Packages only the tracked, top-level runtime files. Refuses *.db, fixtures/, config.json and *.log.
# Needs git, and gh (GitHub CLI, signed in) for the upload.
param(
    [string]$Version,
    [switch]$NoUpload,
    [string]$Notes = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'AroniumSync.psm1') -Force
if (-not $Version) { $Version = Get-InstalledVersion -AppDir $root }
if ($Version -notmatch '^v\d+\.\d+\.\d+$') { throw "Version '$Version' is not like v1.2.3. Fix the VERSION file." }

Push-Location $root
try {
    if (@(git status --porcelain).Count -gt 0) { throw 'Working tree is not clean. Commit or stash first.' }
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    if ($branch -ne 'master') { throw "On branch '$branch'. Releases are cut from master." }
    git rev-parse -q --verify "refs/tags/$Version" *> $null
    if ($LASTEXITCODE -eq 0) { throw "Tag $Version already exists. Bump VERSION." }

    # Tracked, top-level runtime files only (no tests, tools or fixtures).
    $files = @(git ls-files | Where-Object { $_ -notmatch '/' -and ($_ -match '\.(ps1|psm1|md)$' -or $_ -in @('VERSION', 'config.example.json')) })
    Assert-ReleaseFiles -Paths $files

    $out = Join-Path $root 'dist'
    $pkg = New-ReleasePackage -Root $root -Version $Version -Files $files -OutDir $out

    # Check the zip exactly as a client would before it goes anywhere.
    $check = Join-Path $env:TEMP ('ar-sync-release-check-' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $pkg.Zip -DestinationPath $check -Force
        [void](Test-UpdatePackage -Dir $check -ExpectedVersion $Version)
    } finally { Remove-Item -LiteralPath $check -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host "Built $($pkg.Zip)"
    Write-Host "      $($pkg.Sha256File)  ($($pkg.Hash))"
    Write-Host ("Files: " + ($files -join ', '))
    if ($NoUpload) { Write-Host 'NoUpload: nothing tagged or published.'; return }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh (GitHub CLI) is not installed. Install it and run gh auth login.' }
    git tag -a $Version -m "ar-sync $Version"
    if ($LASTEXITCODE -ne 0) { throw 'git tag failed' }
    git push origin $Version
    if ($LASTEXITCODE -ne 0) { throw 'git push of the tag failed' }
    if (-not $Notes) { $Notes = "Aronium Sync $Version. Laptops with auto-update pick this up within a day." }
    gh release create $Version $pkg.Zip $pkg.Sha256File --repo huenique/ar-sync --title "ar-sync $Version" --notes $Notes --verify-tag
    if ($LASTEXITCODE -ne 0) { throw 'gh release create failed (the tag is pushed; fix and rerun gh release create by hand)' }
    Write-Host "Published $Version."
} finally { Pop-Location }
