# Release script for OMOP ETL pipeline
# Usage: .\scripts\release.ps1 -Version "1.1.0" -Message "July 2026 vocabulary release"

param(
    [Parameter(Mandatory=$true, HelpMessage="Version in format MAJOR.MINOR.PATCH (e.g., 1.1.0)")]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,
    
    [Parameter(Mandatory=$true, HelpMessage="Release message describing the changes")]
    [string]$Message,
    
    [Parameter(Mandatory=$false, HelpMessage="Skip git operations (useful for dry-run)")]
    [switch]$SkipGit
)

$ErrorActionPreference = "Stop"

# Validate we're in a git repository
if (-not (Test-Path ".git")) {
    Write-Error "This script must be run from the root of the git repository"
    exit 1
}

$TagName = "omop-etl-v$Version"
$VersionString = "v$Version"
$ChangelogPath = "CHANGELOG.md"
$ReleaseDocPath = "docs/RELEASES.md"

Write-Host "`n=== OMOP ETL Release Script ===" -ForegroundColor Cyan
Write-Host "Version: $VersionString" -ForegroundColor White
Write-Host "Tag: $TagName" -ForegroundColor White
Write-Host "Message: $Message`n" -ForegroundColor White

# Check if tag already exists
$existingTag = git tag -l $TagName
if ($existingTag) {
    Write-Error "Tag $TagName already exists. Use a different version or delete the existing tag."
    exit 1
}

# Require a version section in CHANGELOG before creating the release
if (-not (Test-Path $ChangelogPath)) {
    Write-Error "Missing $ChangelogPath. Add release notes before creating a tag."
    exit 1
}

$changelog = Get-Content -Path $ChangelogPath -Raw
$expectedHeading = "## Version $TagName"
if ($changelog -notmatch "(?m)^##\s+Version\s+$([regex]::Escape($TagName))\s*$") {
    Write-Error "CHANGELOG entry not found. Add heading '$expectedHeading' before creating a release."
    exit 1
}

# Check for uncommitted changes
$status = git status --porcelain
if ($status -and -not $SkipGit) {
    Write-Warning "You have uncommitted changes in your working directory."
    $continue = Read-Host "Do you want to continue? (y/n)"
    if ($continue -ne 'y') {
        Write-Host "Release cancelled." -ForegroundColor Yellow
        exit 0
    }
}

if (-not $SkipGit) {
    # Update VERSION file
    Write-Host "Updating VERSION file..." -ForegroundColor Green
    Set-Content -Path "VERSION" -Value $VersionString -NoNewline
    
    # Stage release metadata and notes
    git add VERSION
    git add $ChangelogPath
    if (Test-Path $ReleaseDocPath) {
        git add $ReleaseDocPath
    }

    git commit -m "chore(release): $VersionString"
    
    # Create git tag
    Write-Host "Creating git tag: $TagName..." -ForegroundColor Green
    git tag -a $TagName -m $Message
    
    Write-Host "`nRelease $VersionString created successfully." -ForegroundColor Green
    Write-Host "`nNext steps:" -ForegroundColor Yellow
    Write-Host "   1. Push commits: git push" -ForegroundColor White
    Write-Host "   2. Push tag: git push origin $TagName" -ForegroundColor White
    Write-Host "   3. Run ETL with appropriate production config file`n" -ForegroundColor White
} else {
    Write-Host "`nDry-run mode: Would have created tag $TagName" -ForegroundColor Yellow
    Write-Host "   Run without -SkipGit to perform actual operations`n" -ForegroundColor White
}

# Show git log
Write-Host "Recent commits:" -ForegroundColor Cyan
git log --oneline -5
