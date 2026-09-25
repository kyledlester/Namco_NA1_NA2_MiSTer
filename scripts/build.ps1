# Command-line build of the Namco_NA1_NA2 core (same result as Processing >
# Start Compilation in the Quartus GUI). The post-flow script copies the RBF
# to Releases/Namco_NA1_NA2_YYYYMMDD.rbf.
param([string]$QuartusRoot = 'C:\intelFPGA_lite\17.0\quartus')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    & (Join-Path $QuartusRoot 'bin64\quartus_sh.exe') --flow compile Namco_NA1_NA2
    if ($LASTEXITCODE -ne 0) { throw 'Quartus build failed; inspect the output_files reports.' }
} finally { Pop-Location }
