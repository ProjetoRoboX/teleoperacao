# Liga servidor + robo com um comando e mostra o link para o operador.
# Uso (normalmente via iniciar.bat):
#   .\iniciar.ps1                 -> rede local
#   .\iniciar.ps1 -Internet       -> tambem cria link https publico (precisa do cloudflared)
#   .\iniciar.ps1 -Sintetica      -> video de teste, sem webcam
#   .\iniciar.ps1 -SemMarca       -> nao grava a hora nos pixels (o operador deixa de ver o atraso do video)
param(
    [switch]$Internet,
    [switch]$Sintetica,
    [switch]$SemMarca,
    [int]$Porta = 8000
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Novo-Token {
    $b = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return ([Convert]::ToBase64String($b) -replace '[^a-zA-Z0-9]', '').Substring(0, 20)
}

# Roda um programa externo sem que o texto dele no stderr (avisos do pip, tracebacks)
# vire erro fatal do PowerShell 5.1. Devolve o codigo de saida.
function Rodar {
    param([string]$Programa, [string[]]$Argumentos, [switch]$Silencioso)
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Silencioso) { & $Programa @Argumentos 2>&1 | Out-Null } else { & $Programa @Argumentos 2>&1 | ForEach-Object { Write-Host "$_" } }
        return $LASTEXITCODE
    } catch { return 1 } finally { $ErrorActionPreference = $anterior }
}

# --- Python -------------------------------------------------------------------
# "python" pode ser so o atalho da Microsoft Store (nao executa nada): testa de verdade.
$py = $null
foreach ($candidato in @("py", "python", "python3")) {
    if (-not (Get-Command $candidato -ErrorAction SilentlyContinue)) { continue }
    if ((Rodar $candidato @("-c", "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)") -Silencioso) -eq 0) {
        $py = $candidato; break
    }
}
if (-not $py) { Write-Host "Python 3.10+ nao encontrado. Instale em python.org (marque 'Add python.exe to PATH')." -ForegroundColor Red; exit 1 }
Write-Host "Usando: $(& $py --version)" -ForegroundColor DarkGray

# --- Dependencias -------------------------------------------------------------
if ((Rodar $py @("-c", "import fastapi, uvicorn, websockets, aiortc, av, numpy, cv2, sounddevice") -Silencioso) -ne 0) {
    Write-Host "Instalando dependencias (so na primeira vez)..." -ForegroundColor Yellow
    $codigo = Rodar $py @("-m", "pip", "install", "-r", "requirements.txt")
    if ($codigo -ne 0) { Write-Host "Falha ao instalar as dependencias (testado com Python 3.14)." -ForegroundColor Red; exit 1 }
}

# --- Tokens (novos a cada execucao; herdados pelas janelas filhas) -------------
$env:TOKEN_ROBO = Novo-Token
$env:TOKEN_OPERADOR = Novo-Token
$env:TOKEN_CLIENTE = Novo-Token
$env:SERVIDOR_PORTA = "$Porta"
$env:URL_SERVIDOR = "ws://127.0.0.1:$Porta/ws"
if ($Sintetica) { $env:SINTETICA = "1" }
# hora da captura gravada nos pixels: o operador ve o atraso real do video (meta < 300 ms)
$env:MARCAR_TIMESTAMP = $(if ($SemMarca) { "0" } else { "1" })

# --- Firewall (so se estiver como administrador) -------------------------------
try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin -and -not (Get-NetFirewallRule -DisplayName "Teleoperacao $Porta" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Teleoperacao $Porta" -Direction Inbound -Protocol TCP -LocalPort $Porta -Action Allow -Profile Private | Out-Null
    }
} catch {}

# --- Servidor e robo, cada um na sua janela ------------------------------------
Write-Host "Ligando o servidor..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList "-NoExit", "-Command", "`$host.UI.RawUI.WindowTitle='SERVIDOR'; $py -m servidor"
Start-Sleep -Seconds 3
Write-Host "Ligando o robo..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList "-NoExit", "-Command", "`$host.UI.RawUI.WindowTitle='ROBO'; $py -m robo"

# --- Links ---------------------------------------------------------------------
$ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.InterfaceAlias -notmatch "vEthernet|VirtualBox|VMware|Loopback" } |
    Select-Object -First 1 -ExpandProperty IPAddress
$t = $env:TOKEN_OPERADOR
$c = $env:TOKEN_CLIENTE

Write-Host ""
Write-Host "================ PRONTO ================" -ForegroundColor Green
Write-Host "OPERADOR (voce - supervisiona, aceita pedidos, ve o video):" -ForegroundColor Cyan
Write-Host "  http://127.0.0.1:$Porta/operador/?token=$t"
Write-Host "CLIENTES (amigos/usuarios - audio e chat):" -ForegroundColor Cyan
if ($ip) {
    Write-Host "  mesma rede:  http://${ip}:$Porta/cliente/?token=$c"
} else {
    Write-Host "  neste computador:  http://127.0.0.1:$Porta/cliente/?token=$c"
}

if ($Internet) {
    if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "Para link pela internet instale o cloudflared (uma vez):" -ForegroundColor Yellow
        Write-Host "  winget install Cloudflare.cloudflared"
        Write-Host "Depois feche e abra o PowerShell e rode de novo com -Internet."
    } else {
        $log = Join-Path $env:TEMP "cloudflared-teleop.log"
        Remove-Item $log -ErrorAction SilentlyContinue
        Start-Process cloudflared -ArgumentList "tunnel", "--url", "http://127.0.0.1:$Porta" -RedirectStandardError $log -WindowStyle Hidden
        Write-Host ""
        Write-Host "Criando link publico (ate 30 s)..." -ForegroundColor Cyan
        $url = $null
        for ($i = 0; $i -lt 30 -and -not $url; $i++) {
            Start-Sleep -Seconds 1
            if (Test-Path $log) {
                $m = Select-String -Path $log -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($m) { $url = $m.Matches[0].Value }
            }
        }
        if ($url) {
            Write-Host "Pela internet (HTTPS, microfone liberado):"
            Write-Host "  CLIENTES:  $url/cliente/?token=$c"
            Write-Host "  OPERADOR:  $url/operador/?token=$t"
            Write-Host "ATENCAO: o link do OPERADOR controla o robo e mostra a camera. NAO o envie a clientes." -ForegroundColor Yellow
            Write-Host "Quem tem o link de CLIENTE so pede atendimento; voce precisa aceitar." -ForegroundColor Yellow
        } else {
            Write-Host "Nao consegui obter o link. Veja o log: $log" -ForegroundColor Red
        }
    }
}

Write-Host "========================================" -ForegroundColor Green
Write-Host "Para desligar tudo: feche as janelas SERVIDOR e ROBO (ou Ctrl+C em cada uma)."
Write-Host "Os tokens mudam a cada vez que voce roda este script."
