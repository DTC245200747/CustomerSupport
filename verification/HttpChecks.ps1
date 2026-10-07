param([switch]$CaptureBrowser)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$artifacts = Join-Path $projectRoot 'verification-artifacts'
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
$run = Join-Path $artifacts ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$base = 'http://localhost:5181'
$randomBytes = New-Object byte[] 24
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$random.GetBytes($randomBytes)
$random.Dispose()
$password = [Convert]::ToBase64String($randomBytes) + 'aA1!'
$environmentNames = @('ConnectionStrings__DefaultConnection','ASPNETCORE_ENVIRONMENT','BootstrapAdmin__Email','BootstrapAdmin__Password','Gemini__ApiKey','AiSettings__StorageDirectory','Logging__LogLevel__Default')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Check($condition, $name) { if (!$condition) { throw "FAILED: $name" }; Write-Output "PASS: $name" }
function Page($path, $session) { Invoke-WebRequest -Uri ($base + $path) -WebSession $session -UseBasicParsing }
function Token($response) { $match = [regex]::Match($response.Content, 'name="__RequestVerificationToken"[^>]*value="([^"]+)"'); if (!$match.Success) { throw 'CSRF token missing' }; [Net.WebUtility]::HtmlDecode($match.Groups[1].Value) }
function PostForm($path, $session, $fields, $tokenPage) { $fields['__RequestVerificationToken'] = Token $tokenPage; Invoke-WebRequest -Uri ($base + $path) -WebSession $session -Method Post -Headers @{RequestVerificationToken=$fields['__RequestVerificationToken']} -Body $fields -UseBasicParsing }
function JsonPost($path, $session, $payload, $token) { Invoke-WebRequest -Uri ($base + $path) -WebSession $session -Method Post -ContentType 'application/json; charset=utf-8' -Headers @{RequestVerificationToken=$token} -Body ([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json))) -UseBasicParsing }
function StatusOf($script) { try { (& $script).StatusCode } catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { throw } } }
$server = $null
try {
    $env:ConnectionStrings__DefaultConnection = 'Data Source=' + (Join-Path $run 'test.db')
    $env:ASPNETCORE_ENVIRONMENT = 'Development'
    $env:BootstrapAdmin__Email = 'admin@test.local'
    $env:BootstrapAdmin__Password = $password
    $env:Gemini__ApiKey = ''
    $env:AiSettings__StorageDirectory = Join-Path $run 'settings'
    $env:Logging__LogLevel__Default = 'Warning'
    $dll = Join-Path $projectRoot 'bin\Debug\net10.0\CustomerSupportAI.dll'
    $server = Start-Process -FilePath 'dotnet' -ArgumentList @('"' + $dll + '"', '--urls', $base) -WorkingDirectory $projectRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $run 'server.log') -RedirectStandardError (Join-Path $run 'server-error.log') -PassThru
    $ready = $false
    for ($attempt=0; $attempt -lt 30; $attempt++) { try { $null = Invoke-WebRequest -Uri $base -UseBasicParsing; $ready=$true; break } catch { Start-Sleep -Milliseconds 500 } }
    Check $ready 'isolated server starts without modifying live data'
    $one = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $two = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $admin = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $landingPage = Page '/' $one
    Check ($landingPage.Content -match 'landing-hero') 'public landing page renders'
    Check ((Page '/Knowledge' $one).StatusCode -eq 200) 'knowledge library available without signing in'
    $registration = Page '/Account/Register' $one
    $registered = PostForm '/Account/Register' $one @{DisplayName='HTTP Test Customer';Email='one@test.local';Password=$password;ConfirmPassword=$password} $registration
    Check ($registered.Content -match 'stats-grid') 'registration signs customer in to dashboard'
    foreach ($path in @('/Dashboard','/Tickets','/Assistant','/Knowledge','/Dashboard/Activity','/Account/Profile','/Account/ChangePassword')) { Check ((Page $path $one).StatusCode -eq 200) "customer page $path" }
    $ticketPage = Page '/Tickets/Create' $one
    $ticket = PostForm '/Tickets/Create' $one @{Subject='HTTP test ticket';Category='Account access';FirstMessage='I cannot access my account, please help.'} $ticketPage
    Check ($ticket.Content -match 'HTTP test ticket') 'customer creates support ticket'
    $ticketId = [regex]::Match($ticket.Content, 'name="TicketId" value="(\d+)"').Groups[1].Value
    Check ($ticketId.Length -gt 0) 'ticket detail includes correct reply target'
    $reply = PostForm '/Tickets/Reply' $one @{TicketId=$ticketId;Body='Additional details from the customer'} $ticket
    Check ($reply.Content -match 'Additional details from the customer') 'customer replies to own ticket'
    $filtered = Page '/Tickets?search=HTTP&status=Open' $one
    Check ($filtered.Content -match 'HTTP test ticket') 'ticket search and status filter'
    $otherRegistration = Page '/Account/Register' $two
    $null = PostForm '/Account/Register' $two @{DisplayName='Second Customer';Email='two@test.local';Password=$password;ConfirmPassword=$password} $otherRegistration
    Check ((StatusOf { Page "/Tickets/Details/$ticketId" $two }) -eq 404) 'another customer cannot read private ticket'
    $denied = Page '/Settings' $one
    Check ($denied.BaseResponse.ResponseUri.AbsolutePath -eq '/Account/AccessDenied') 'customer cannot access AI settings'
    $assistantPage = Page '/Assistant' $one
    $token = Token $assistantPage
    $answer = JsonPost '/Assistant/Ask' $one @{message='Làm thế nào để đổi mật khẩu tài khoản?'} $token
    $data = $answer.Content | ConvertFrom-Json
    Check ($data.mode -eq 'knowledge' -and $data.sources.Count -gt 0) 'assistant returns disclosed knowledge mode with sources'
    Check (([Net.WebUtility]::HtmlDecode((Page '/Assistant' $one).Content)) -match 'Làm thế nào để đổi mật khẩu') 'assistant history persists on reload'
    Check (!(([Net.WebUtility]::HtmlDecode((Page '/Assistant' $two).Content)) -match 'Làm thế nào để đổi mật khẩu')) 'assistant history isolated by user'
    $status = (JsonPost '/Assistant/Ask' $one @{message='Trạng thái yêu cầu của tôi là gì?'} $token).Content | ConvertFrom-Json
    Check ($status.reply -match 'HTTP test ticket') 'assistant retrieves own ticket status without provider key'
    Check ((StatusOf { JsonPost '/Assistant/Ask' $one @{message='  '} $token }) -eq 400) 'blank assistant question rejected'
    Check ((StatusOf { JsonPost '/Assistant/Ask' $one @{message='hello'} 'invalid' }) -eq 400) 'assistant rejects invalid CSRF token'
    $handoff = PostForm '/Assistant/Handoff' $one @{} $assistantPage
    Check (([Net.WebUtility]::HtmlDecode($handoff.Content)) -match 'Cuộc trao đổi gần đây') 'handoff creates ticket with recent conversation'
    $null = PostForm '/Assistant/Clear' $one @{} (Page '/Assistant' $one)
    Check (!(([Net.WebUtility]::HtmlDecode((Page '/Assistant' $one).Content)) -match 'Làm thế nào để đổi mật khẩu')) 'new conversation clears own history'
    $login = Page '/Account/Login' $admin
    $signedAdmin = PostForm '/Account/Login' $admin @{Email='admin@test.local';Password=$password} $login
    Check ($signedAdmin.Content -match 'stats-grid') 'administrator login'
    Check ((Page '/Admin/Users' $admin).StatusCode -eq 200) 'administrator account directory'
    $settingsPage = Page '/Settings' $admin
    $saved = PostForm '/Settings' $admin @{Model='test-model';ApiKey='test-key-for-encryption'} $settingsPage
    Check ($saved.Content -match 'value="test-model"' -and $saved.Content -notmatch 'test-key-for-encryption') 'admin saves model and key is never redisplayed'
    $settingsFile = Join-Path $run 'settings\gemini-settings.json'
    Check ((Get-Content -Raw $settingsFile) -notmatch 'test-key-for-encryption') 'admin key encrypted on disk'
    $null = PostForm '/Settings' $admin @{Model='gemini-3.8-flash';RemoveKey='true'} $saved
    $edit = Page '/Knowledge/Edit' $admin
    $created = PostForm '/Knowledge/Edit' $admin @{Id=0;Title='Verified policy';Category='Tài khoản';Body='Verified content for assistant knowledge retrieval.'} $edit
    Check ($created.Content -match 'Verified content') 'admin publishes knowledge article'
    $staffPage = Page '/Admin/Users' $admin
    $staffCreated = PostForm '/Admin/CreateStaff' $admin @{'NewStaff.DisplayName'='Test Staff';'NewStaff.Email'='staff@test.local';'NewStaff.TemporaryPassword'=$password} $staffPage
    Check ($staffCreated.Content -match 'staff@test.local') 'admin creates support staff account'
    $updated = PostForm '/Tickets/UpdateStatus' $admin @{id=$ticketId;status='Resolved'} (Page "/Tickets/Details/$ticketId" $admin)
    Check (([Net.WebUtility]::HtmlDecode($updated.Content)) -match 'Đã giải quyết') 'staff role can update ticket status'
    $closed = PostForm '/Tickets/UpdateStatus' $admin @{id=$ticketId;status='Closed'} $updated
    Check ($closed.Content -notmatch 'id="reply-body"') 'closed ticket disables reply composer'
    $attemptedReply = PostForm '/Tickets/Reply' $one @{TicketId=$ticketId;Body='This must not be accepted'} (Page "/Tickets/Details/$ticketId" $one)
    Check ($attemptedReply.Content -notmatch 'This must not be accepted') 'server rejects replies to closed ticket'
    $newPassword = $password + 'new'
    $changed = PostForm '/Account/ChangePassword' $one @{CurrentPassword=$password;NewPassword=$newPassword;ConfirmPassword=$newPassword} (Page '/Account/ChangePassword' $one)
    Check ($changed.StatusCode -eq 200) 'customer changes password'
    $null = PostForm '/Account/Logout' $one @{} (Page '/Account/Profile' $one)
    $relogin = PostForm '/Account/Login' $one @{Email='one@test.local';Password=$newPassword} (Page '/Account/Login' $one)
    Check ($relogin.Content -match 'stats-grid') 'new password authenticates'
    $token = Token (Page '/Assistant' $two)
    $limited = $false
    for ($i=0; $i -lt 14; $i++) { if ((StatusOf { JsonPost '/Assistant/Ask' $two @{message='Tạo yêu cầu hỗ trợ'} $token }) -eq 429) { $limited=$true;break } }
    Check $limited 'assistant request limit enforced'
    Write-Output 'All HTTP checks passed. Production database was not modified.'
    if ($CaptureBrowser) {
        $cookieFile = Join-Path $run 'browser-cookies.json'
        $cookieData = @($one.Cookies.GetCookies([Uri]$base) | ForEach-Object { @{Name=$_.Name;Value=$_.Value} })
        [IO.File]::WriteAllText($cookieFile, (ConvertTo-Json -InputObject $cookieData))
        & dotnet run --project (Join-Path $PSScriptRoot 'BrowserChecks\BrowserChecks.csproj') --no-build -- $base $cookieFile $artifacts
        if ($LASTEXITCODE -ne 0) { throw 'Browser checks failed' }
    }
} finally {
    if ($server -and !$server.HasExited) { Stop-Process -Id $server.Id -Force }
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
}
