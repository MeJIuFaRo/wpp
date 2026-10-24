# Copy the local repository (source of truth) to the build host and commit the
# snapshot there. upstream/ and build/ live only on the build host.
#   scripts/sync-to-build.ps1 -BuildHost 10.0.0.5 [-RemoteDir /root/web-panel-proxy]
#                             [-Key ~/.ssh/id_ed25519] [-LogDir C:\logs]
param(
    [Parameter(Mandatory)][string]$BuildHost,
    [string]$RemoteDir = '/root/web-panel-proxy',
    [string]$Key = (Join-Path $HOME '.ssh\id_ed25519'),
    [string]$LogDir = '',
    [string]$Message = "sync $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$archive = Join-Path ([IO.Path]::GetTempPath()) "wpp-sync-$PID.tar.gz"
$ssh = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-i', $Key)

tar --no-fflags --no-xattrs -C $root --exclude=./upstream --exclude=./build --exclude=./deploy/config --exclude=./deploy/data `
    --exclude=./deploy/.env --exclude=__pycache__ -czf $archive .
if ($LASTEXITCODE) { throw 'tar failed' }

$remote = @"
set -e
mkdir -p $RemoteDir
cd $RemoteDir
find . -mindepth 1 -maxdepth 1 ! -name .git ! -name upstream ! -name build -exec rm -rf {} +
tar -xzf /tmp/wpp-sync.tar.gz && rm -f /tmp/wpp-sync.tar.gz
chmod +x scripts/*.sh tests/*.sh deploy/*.sh 2>/dev/null || true
[ -d .git ] || { git init -q -b main && git config user.name 'wpp-build' && git config user.email 'wpp-build@localhost'; }
git add -A
git diff --cached --quiet || git commit -q -m '$Message'
git log -1 --format='%h %s'
"@
$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
scp @ssh $archive "root@${BuildHost}:/tmp/wpp-sync.tar.gz"
if ($LASTEXITCODE) { throw 'scp failed' }
$out = ssh @ssh "root@$BuildHost" $remote 2>&1 | Out-String
if ($LogDir) {
    Add-Content -Path (Join-Path $LogDir "$BuildHost.txt") -Encoding utf8 -Value "[$ts] scp repo -> ${BuildHost}:$RemoteDir; ssh: sync + git commit`r`nResult: $out`r`n"
}
Remove-Item $archive -Force
$out
