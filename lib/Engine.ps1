# Engine.ps1 - one test (one CSV row): CCP -> logon -> account -> PSMConnect -> RDP session -> recording. Passwords stay in memory.
# Dot-sourced by Run-PsmTests.ps1 (needs Core.ps1 first).

# ------------------------------------------------------------------ the RDP client: fixed key table lives HERE and nowhere else
# Compiled on first use only (needs Windows + an interactive desktop), so every other function can be tested anywhere.
function Initialize-Rdp {
  if ('PsmRdp' -as [type]) { return }
  Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[ComImport, Guid("c1e6743a-41c1-4a74-832a-0dd06c1c7a0e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMsTscNonScriptable { [PreserveSig] int put_ClearTextPassword([MarshalAs(UnmanagedType.BStr)] string pw); }

public class PsmRdpHost : AxHost {
  public PsmRdpHost(string clsid) : base(clsid) { }
  public object Ocx { get { return this.GetOcx(); } }
}

public static class PsmRdp {
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();      // real pixels, so the capture area is right on scaled displays
  // picture of the RDP window area while the session is open (JPEG bytes in memory); null if the area is blank (locked screen / nothing drawn yet)
  static byte[] Shot(Control c) {
    try {
      System.Drawing.Rectangle r = c.RectangleToScreen(c.ClientRectangle);
      if (r.Width < 100 || r.Height < 100) return null;
      using (System.Drawing.Bitmap bmp = new System.Drawing.Bitmap(r.Width, r.Height)) {
        using (System.Drawing.Graphics g = System.Drawing.Graphics.FromImage(bmp)) { g.CopyFromScreen(r.Location, System.Drawing.Point.Empty, r.Size); }
        System.Drawing.Color c0 = bmp.GetPixel(bmp.Width / 2, bmp.Height / 2); int same = 0, n = 0;
        for (int y = 10; y < bmp.Height; y += bmp.Height / 12) for (int x = 10; x < bmp.Width; x += bmp.Width / 16) {
          System.Drawing.Color px = bmp.GetPixel(x, y); n++;
          if (Math.Abs(px.R - c0.R) + Math.Abs(px.G - c0.G) + Math.Abs(px.B - c0.B) < 12) same++;
        }
        if (same == n) return null;
        ImageCodecInfo codec = null; foreach (ImageCodecInfo ci in ImageCodecInfo.GetImageEncoders()) { if (ci.MimeType == "image/jpeg") codec = ci; }
        EncoderParameters ep = new EncoderParameters(1); ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 70L);
        using (MemoryStream ms = new MemoryStream()) { bmp.Save(ms, codec, ep); return ms.ToArray(); }
      }
    } catch (Exception) { return null; }
  }
  static object Get(object o, string n) { return o.GetType().InvokeMember(n, BindingFlags.GetProperty, null, o, null); }
  static void Set(object o, string n, object v) { o.GetType().InvokeMember(n, BindingFlags.SetProperty, null, o, new object[] { v }); }
  static void TryAdv(object ocx, string prop, object val) {   // property lives on a different AdvancedSettingsN depending on the OS version
    for (int i = 9; i >= 2; i--) { try { Set(Get(ocx, "AdvancedSettings" + i), prop, val); return; } catch (Exception) { } }
  }
  // Fixed table: the ONLY keys that can ever be sent. Anything else is refused.
  static string KeyFor(string name) {
    switch (name) { case "Enter": return "{ENTER}"; case "Y": return "y"; case "A": return "a"; default: return null; }
  }
  // returns "OK|<seconds>|<keylog>" or "ERR|<reason>|<keylog>"
  public static string Run(string server, int port, string user, string pw, string shell, int hold, int keyAfter, int keyCount, string keyName, string shotPath, int shotEvery) {
    byte[] lastShot = null; try { SetProcessDPIAware(); } catch (Exception) { }
    string sk = null; StringBuilder kl = new StringBuilder(), ev = new StringBuilder();
    if (keyAfter > 0) {
      sk = KeyFor(keyName);
      if (sk == null || keyCount < 1 || keyCount > 3 || keyAfter > 120) return "ERR|prompt option refused|";
    }
    Type t = Type.GetTypeFromProgID("MsTscAx.MsTscAx");
    if (t == null) return "ERR|RDP ActiveX (MsTscAx) not available on this host|";
    Form form = new Form(); form.Text = "PSM health test"; form.ClientSize = new System.Drawing.Size(1024, 768); form.StartPosition = FormStartPosition.CenterScreen; if (shotPath != null) form.TopMost = true;
    PsmRdpHost rdp = new PsmRdpHost(t.GUID.ToString("B")); rdp.Dock = DockStyle.Fill; form.Controls.Add(rdp);
    form.Show(); Application.DoEvents();
    Stopwatch sw = Stopwatch.StartNew();
    try {
      object ocx = rdp.Ocx;
      Set(ocx, "Server", server); Set(ocx, "UserName", user);
      Set(ocx, "DesktopWidth", 1024); Set(ocx, "DesktopHeight", 768);
      TryAdv(ocx, "RDPPort", port); TryAdv(ocx, "EnableCredSspSupport", true); TryAdv(ocx, "AuthenticationLevel", 0); TryAdv(ocx, "EnableAutoReconnect", false);
      Set(Get(ocx, "SecuredSettings"), "StartProgram", shell);
      int hr = ((IMsTscNonScriptable)ocx).put_ClearTextPassword(pw);
      if (hr != 0) return "ERR|could not hand the password to the RDP control (hr=" + hr + ")|";
      ocx.GetType().InvokeMember("Connect", BindingFlags.InvokeMethod, null, ocx, null); ev.Append("connect requested at +" + (int)sw.Elapsed.TotalSeconds + "s;");
      bool up = false; int sent = 0; double next = keyAfter; double nextShot = shotEvery > 0 ? shotEvery : 5;
      while (sw.Elapsed.TotalSeconds < hold) {
        Application.DoEvents(); Thread.Sleep(200);
        int c = Convert.ToInt32(Get(ocx, "Connected"));
        if (c == 1) { if (!up) ev.Append("connected at +" + (int)sw.Elapsed.TotalSeconds + "s;"); up = true; }
        else if (up) { ev.Append("server closed the session at +" + (int)sw.Elapsed.TotalSeconds + "s;"); return "ERR|RDP session was closed by the server after " + (int)sw.Elapsed.TotalSeconds + "s (hold " + hold + "s)|" + kl + "|" + ev; }
        else if (sw.Elapsed.TotalSeconds > 60) return "ERR|RDP never connected to " + server + ":" + port + " within 60s|" + kl + "|" + ev;
        if (shotPath != null && up && sw.Elapsed.TotalSeconds >= nextShot) { byte[] b = Shot(rdp); if (b != null) lastShot = b; nextShot += (shotEvery > 0 ? shotEvery : 5); }
        if (sk != null && sent < keyCount && sw.Elapsed.TotalSeconds >= next) {
          form.Activate(); rdp.Focus(); SendKeys.SendWait(sk); sent++; next += 2;
          kl.Append("key " + keyName + " sent #" + sent + " at +" + (int)sw.Elapsed.TotalSeconds + "s;"); ev.Append("key " + keyName + " pressed #" + sent + " at +" + (int)sw.Elapsed.TotalSeconds + "s;");
        }
      }
      if (shotPath != null) { form.Activate(); Application.DoEvents(); byte[] b2 = Shot(rdp); if (b2 != null) lastShot = b2; }
      ev.Append("hold complete at +" + (int)sw.Elapsed.TotalSeconds + "s, disconnecting;");
      try { ocx.GetType().InvokeMember("Disconnect", BindingFlags.InvokeMethod, null, ocx, null); } catch (Exception) { }
      for (int i = 0; i < 40 && Convert.ToInt32(Get(ocx, "Connected")) != 0; i++) { Application.DoEvents(); Thread.Sleep(250); }
      ev.Append("disconnected at +" + (int)sw.Elapsed.TotalSeconds + "s;");
      return "OK|" + (int)sw.Elapsed.TotalSeconds + "|" + kl + "|" + ev;
    } catch (Exception ex) {
      return "ERR|" + ex.GetType().Name + ": " + ex.Message.Replace('|', '/') + "|" + kl + "|" + ev;
    } finally {
      try { if (shotPath != null && lastShot != null) File.WriteAllBytes(shotPath, lastShot); } catch (Exception) { }
      try { form.Close(); form.Dispose(); } catch (Exception) { }
    }
  }
}
'@
}

# ------------------------------------------------------------------ one test (one CSV row)
function Invoke-Test([hashtable]$S, [string]$OutFile) {
  $HoldSec = if ($S.WAIT) { [int]$S.WAIT } elseif ($Hold -gt 0) { $Hold } else { $script:HoldSec }   # per-row HoldSec, then -Hold, then env.json

  $log = New-Object Collections.Generic.List[string]
  function Note([string]$m) { $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $m; $log.Add($line); Write-Host "    $line" }
  $Reason = Get-RunReason $script:Reason      # base text from env.json + day and time of this attempt; used for the CCP and the PSMConnect call
  Note "reason sent to CCP and PVWA: $Reason"
  $ctx = @{ pw = $null; tok = $null; hdr = @{}; acctId = ''; acctUser = ''; acctAddr = ''; addr = ''; port = 3389; rus = ''; shell = ''; Problems = @(); Failed = ''
            R = @{}; PSMReturned = ''; RecId = ''; RecSec = 0; Shot = '' }
  foreach ($n in $StepNames) { $ctx.R[$n] = 'not run' }
  $since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $hard = 'ccp', 'logon', 'account', 'connect'
  function Step([string]$name, [scriptblock]$sb) {
    $swS = [Diagnostics.Stopwatch]::StartNew()
    try { & $sb; $ctx.R[$name] = 'OK'; Write-Trace "step $name : OK in $($swS.ElapsedMilliseconds) ms" }
    catch { Write-Trace "step $name : FAIL in $($swS.ElapsedMilliseconds) ms - $($_.Exception.Message)"; $ctx.R[$name] = 'FAIL'; $ctx.Problems += ('{0}: {1}' -f $name, $_.Exception.Message); if (-not $ctx.Failed) { $ctx.Failed = $name }; if ($hard -contains $name) { throw 'HARD' } }
  }
  $doCcp = {
    if ($script:ManualCred) {    # manual credentials: typed by the operator at the start of the run, kept only in memory (SecureString), same for every row
      $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:ManualCred.Password)
      try { $ctx.pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
      if (-not $ctx.pw) { throw 'the manual password is empty' }
      Write-Trace 'credential source: MANUAL (typed at the start of the run)'
      Note "credentials: MANUAL for user $($S.PSM_USER) (password length $($ctx.pw.Length), not shown)"
      return
    }
    $u = "$($S.CCP_URL)/AIMWebService/api/Accounts?AppID=$(Q $S.CP_APPID)&Safe=$(Q $S.CP_SAFE)&Object=$(Q $S.CP_OBJECT)&Reason=$(Q $Reason)"
    $ccpAuth = Get-CcpAuth $script:Settings
    $x = Http GET $u $null $null $ccpAuth.Params
    if ($x.Code -ne 200) { throw ('CCP http={0} {1} (authentication sent: {2})' -f $x.Code, (ErrCode $x.Content), $ccpAuth.Desc) }
    $j = $x.Content | ConvertFrom-Json
    if (-not $j.Content -or $j.UserName -ne $S.PSM_USER) { throw "empty password or CCP username '$($j.UserName)' differs from PSM_USER '$($S.PSM_USER)'" }
    $ctx.pw = [string]$j.Content; $j = $null
    Write-Trace "credential source: CCP, authentication sent: $($ccpAuth.Desc)"
    Note "CCP OK (user $($S.PSM_USER), authentication: $($ccpAuth.Desc), password length $($ctx.pw.Length), not shown)"
  }
  $doLogon = {
    $body = @{ username = $S.PSM_USER; password = $ctx.pw } | ConvertTo-Json -Compress
    $x = Http POST "$($S.PVWA)/PasswordVault/API/auth/$($S.AUTH_METHOD)/Logon" $null $body; $body = $null
    if ($x.Code -ne 200) { throw ('REST logon ({0}) http={1} {2}' -f $S.AUTH_METHOD, $x.Code, (ErrCode $x.Content)) }
    $ctx.tok = $x.Content.Trim().Trim('"'); $ctx.hdr = @{ Authorization = $ctx.tok }
    Note "REST logon OK ($($S.AUTH_METHOD))"
  }
  try {
    Step 'ccp' $doCcp
    Step 'logon' $doLogon
    Step 'account' {
      if ($S.ACCT_ID) {     # exact: the CSV gave the account id, so no search is needed
        $x = Http GET "$($S.PVWA)/PasswordVault/API/Accounts/$(Q $S.ACCT_ID)" $ctx.hdr $null
        if ($x.Code -ne 200) { throw "account id $($S.ACCT_ID): $(if ($x.Code -eq 404) { 'not found, or not visible to ' + $S.PSM_USER + ' (needs List accounts)' } else { 'http=' + $x.Code + ' ' + (ErrCode $x.Content) })" }
        $sel = $x.Content | ConvertFrom-Json
        if ($S.ACCT_USER -and $sel.userName -ne $S.ACCT_USER) { throw "TargetAccountID $($S.ACCT_ID) is account '$($sel.userName)', but the CSV says TargetAccount '$($S.ACCT_USER)' (stale id or wrong row?)" }
        if ($S.ACCT_ADDR -and $sel.address -ne $S.ACCT_ADDR) { throw "TargetAccountID $($S.ACCT_ID) has address '$($sel.address)', but the CSV says TargetAccountAddress '$($S.ACCT_ADDR)'" }
        $ctx.acctId = $sel.id; $ctx.acctUser = $sel.userName; $ctx.acctAddr = $sel.address
        Note "target account resolved from TargetAccountID $($S.ACCT_ID) (user $($sel.userName), address $($sel.address), safe $($sel.safeName))"
      } else {
      $x = Http GET "$($S.PVWA)/PasswordVault/API/Accounts?filter=$(Q "safeName eq $($S.ACCT_SAFE)")&limit=1000" $ctx.hdr $null
      if ($x.Code -ne 200) { throw "account list http=$($x.Code)" }
      $sel = @(($x.Content | ConvertFrom-Json).value) | Where-Object { $_ -and $_.userName -eq $S.ACCT_USER -and ((-not $S.ACCT_ADDR) -or $_.address -eq $S.ACCT_ADDR) } | Select-Object -First 1
      if (-not $sel) {
        $why = " [$(@(($x.Content | ConvertFrom-Json).value).Count) account(s) visible to $($S.PSM_USER) in this safe]"
        try {   # help the operator: what does the end user see under that user name in ANY safe? (names only, no secrets)
          $y = Http GET "$($S.PVWA)/PasswordVault/API/Accounts?search=$(Q $S.ACCT_USER)&limit=10" $ctx.hdr $null
          if ($y.Code -eq 200) {
            $m = @(($y.Content | ConvertFrom-Json).value | Where-Object { $_ } | ForEach-Object { "$($_.safeName)/$($_.userName)@$($_.address)" })
            $why += $(if ($m) { " Visible with that name: $($m -join '; ')" } else { " No account matching '$($S.ACCT_USER)' is visible to $($S.PSM_USER) in any safe (check safe membership: List accounts)" })
          }
        } catch { }
        throw "target account '$($S.ACCT_USER)'$(if($S.ACCT_ADDR){" @ $($S.ACCT_ADDR)"}) not visible in safe $($S.ACCT_SAFE)$why"
      }
      $ctx.acctId = $sel.id; $ctx.acctUser = $sel.userName; $ctx.acctAddr = $sel.address
      Note "target account found (id $($sel.id), user $($sel.userName), address $($sel.address))"
      }
    }
    Step 'connect' {
      $b = @{ reason = $Reason; ConnectionComponent = $S.COMPONENT }
      if ($S.TARGET_HOST -and $S.TARGET_HOST -ne $ctx.acctAddr) { $b.ConnectionParams = @{ PSMRemoteMachine = @{ value = $S.TARGET_HOST } } }
      $x = Http POST "$($S.PVWA)/PasswordVault/API/Accounts/$($ctx.acctId)/PSMConnect" $ctx.hdr ($b | ConvertTo-Json -Depth 5 -Compress)
      if ($x.Code -ne 200) { throw ('PSMConnect ({0}) http={1} {2}' -f $S.COMPONENT, $x.Code, (ErrCode $x.Content)) }
      $f = @{}; foreach ($l in ($x.Content -split "`r?`n")) { if ($l -match '^(full address:s|server port:i|username:s|alternate shell:s):(.*)$') { $f[$Matches[1]] = $Matches[2] } }
      if (-not $f['full address:s'] -or -not $f['username:s'] -or -not $f['alternate shell:s']) { throw 'PSMConnect returned an RDP file without address/username/shell' }
      $ctx.addr = $f['full address:s']; $ctx.rus = $f['username:s']; $ctx.shell = $f['alternate shell:s']
      if ($f['server port:i']) { $ctx.port = [int]$f['server port:i'] }
      $ctx.PSMReturned = $ctx.addr
      Write-Trace "PSMConnect: PSM address $($ctx.addr), port $($ctx.port), connection file fields present: $((@($f.Keys) | Sort-Object) -join ', ') (values not logged)"
      Note "PSMConnect OK -> PSM $($ctx.addr):$($ctx.port) shell=$(($ctx.shell -split '@')[0])@<id>"
    }
    Step 'session' {
      $dest = if ($S.PSM_HOST) { $S.PSM_HOST } else { $ctx.addr }
      if ($dest -ne $ctx.addr) { Note "PSM address override: connecting to $dest (PVWA returned $($ctx.addr))" }
      $pa = [int]$S.PROMPT_AFTER; $pc = [int]$S.PROMPT_COUNT; $pk = [string]$S.PROMPT_KEY
      if ($pa -lt 0 -or $pa -gt 120 -or $pc -lt 1 -or $pc -gt 3 -or @('Enter', 'Y', 'A') -notcontains $pk) { throw 'invalid prompt option (DismissPromptAfterSec 0-120, DismissPromptCount 1-3, DismissPromptKey Enter|Y|A)' }
      if ($pa -gt 0) { Note "optional prompt dismiss ON: key $pk x$pc, first press ${pa}s after connecting" }
      if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'the RDP window needs an STA thread: start with powershell.exe -STA -File Run-PsmTests.ps1' }
      Initialize-Rdp
      Write-Trace "RDP: connecting to ${dest}:$($ctx.port), hold ${HoldSec}s, key press: $(if ($pa -gt 0) { "$pk x$pc, first after ${pa}s" } else { 'none' })"
      $pw = $ctx.pw; $ctx.pw = $null
      $rdpStart = Get-Date
      $shotPath = $null; if ($script:ShotMode -ne 'off') { $shotPath = [IO.Path]::ChangeExtension($OutFile, 'screen.jpg') }
      $res = [PsmRdp]::Run($dest, $ctx.port, $ctx.rus, $pw, $ctx.shell, $HoldSec, $pa, $pc, $pk, $shotPath, $script:ShotEvery); $pw = $null
      if ($shotPath) { if (Test-Path -LiteralPath $shotPath) { $ctx.Shot = $shotPath; Note "screenshot of the session saved: $shotPath ($([math]::Round((Get-Item -LiteralPath $shotPath).Length / 1KB)) KB)" } else { Note 'no usable screenshot (the screen was locked or blank, or the session never drew anything)' } }
      $parts = $res.Split('|'); $kl = $parts[2]
      if ($parts.Count -gt 3) { foreach ($ev in ($parts[3] -split ';' | Where-Object { $_ })) { $at = ''; if ($ev -match '\+(\d+)s') { $at = $rdpStart.AddSeconds([int]$Matches[1]).ToString(' (clock HH:mm:ss)') }; Write-Trace "RDP event: $ev$at" } }
      Write-Trace "RDP result: $($parts[0]) $($parts[1])"
      foreach ($k in ($kl -split ';' | Where-Object { $_ })) { Note $k }
      if ($parts[0] -ne 'OK') { throw "RDP session did not stay up for ${HoldSec}s: $($parts[1])" }
      if ([int]$parts[1] -lt ($HoldSec - 2)) { throw "RDP session ended after $($parts[1])s, expected ${HoldSec}s" }
      Note "RDP session held $($parts[1])s and disconnected"
    }
    Step 'recording' {
      if (-not $RecCheck) { Note 'recording check skipped'; return }
      $mind = [math]::Floor(($HoldSec - [int]$S.PROMPT_AFTER) * $MinPct / 100)
      $t = 0; $relog = 0; $rec = $null; $code = 200
      while ($t -le $RecWait) {
        $x = Http GET "$($S.PVWA)/PasswordVault/API/Recordings?limit=100&offset=0&fromTime=$($since - 60)" $ctx.hdr $null
        $code = $x.Code
        if (($code -eq 401 -or $code -eq 404) -and $relog -lt 2) {   # token lost: same user may have logged on elsewhere; log on again (max 2)
          $relog++; Note "Recordings API http=$code - logging on again (retry $relog of 2)"
          & $doCcp; & $doLogon; $ctx.pw = $null; Start-Sleep 3; continue
        }
        if ($code -ne 200) { break }
        $rec = @(($x.Content | ConvertFrom-Json).Recordings) | Where-Object { $_ -and $_.User -ieq $S.PSM_USER -and $_.AccountUsername -ieq $ctx.acctUser -and $_.ConnectionComponentID -eq $S.COMPONENT -and $_.Start -ge ($since - 5) } | Sort-Object Start | Select-Object -Last 1
        Write-Trace "recording poll after ${t}s: http $code, matching recording: $(if ($rec) { $rec.SessionID } else { 'none yet' })"
        if ($rec -and -not $rec.IsLive) { break }
        Start-Sleep 10; $t += 10
      }
      if ($code -ne 200) { throw "Recordings API http=$code" }
      if (-not $rec) {
        $near = @(@(($x.Content | ConvertFrom-Json).Recordings) | Where-Object { $_ -and $_.Start -ge ($since - 5) } | Select-Object -First 5 | ForEach-Object { "$($_.SessionID) user=$($_.User) account=$($_.AccountUsername) component=$($_.ConnectionComponentID) live=$($_.IsLive)" })
        throw "no recording from this session visible within ${RecWait}s (user=$($S.PSM_USER) account=$($ctx.acctUser) component=$($S.COMPONENT))$(if ($near) { ' Recordings seen since the test started: ' + ($near -join '; ') } else { ' No recording of any kind was visible since the test started.' })"
      }
      $ctx.RecId = [string]$rec.SessionID; $ctx.RecSec = [int]$rec.Duration
      Note "recording $($rec.SessionID): protocol=$($rec.Protocol) duration=$($rec.Duration)s live=$($rec.IsLive) safe=$($rec.SafeName)"
      $bad = @()
      if ($rec.IsLive) { $bad += "session still live ${RecWait}s after disconnect (recording $($rec.SessionID))" }
      if ([int]$rec.Duration -lt $mind) { $bad += "recording duration $($rec.Duration)s is shorter than the expected ${mind}s" }
      $a = Http GET "$($S.PVWA)/PasswordVault/API/Recordings/$($rec.SessionID)/activities" $ctx.hdr $null
      $texts = @(); if ($a.Code -eq 200) { $texts = @(($a.Content | ConvertFrom-Json).Activities | ForEach-Object { [string]$_.ActivityText }) }
      Write-Trace "recording activities: http $($a.Code), $(@($texts).Count) window title(s) recorded$(if (@($texts).Count -gt 25) { ' (first 25 shown)' })"
      foreach ($tt in @($texts | Select-Object -First 25)) { Write-Trace ('  title: ' + $tt.Substring(0, [math]::Min(90, $tt.Length))) }
      if ($S.TITLE_EXPECT) {   # success title: proves the target was really reached
        if ($a.Code -ne 200) { $bad += "activities API http=$($a.Code), cannot check the expected window title (recording $($rec.SessionID))" }
        elseif (-not ($texts | Where-Object { $_ -like "*$($S.TITLE_EXPECT)*" })) { $bad += "expected window title '$($S.TITLE_EXPECT)' not seen in the session (recording $($rec.SessionID))" }
        else { Note "expected window title '$($S.TITLE_EXPECT)' seen" }
      }
      if ($TitleCheck -and $a.Code -eq 200) {
        $hit = $texts | Where-Object { $tx = $_; $TitlesErr | Where-Object { $_ -and $tx -like "*$_*" } } | Select-Object -First 1
        if (-not $hit -and $texts.Count -gt 0) { $z = $texts[-1]; if ($TitlesLast | Where-Object { $_ -and $z -like "*$_*" }) { $hit = $z } }
        if ($hit) { $bad += "error window in the session (recording $($rec.SessionID)): $($hit.Substring(0, [math]::Min(110, $hit.Length)))" }
      }
      if ($bad) { throw ($bad -join '; ') }
    }
  } catch { if ($_.Exception.Message -ne 'HARD') { $ctx.Problems += "runner: $($_.Exception.Message)"; if (-not $ctx.Failed) { $ctx.Failed = 'runner' } } }
  finally {
    $ctx.pw = $null
    if ($ctx.tok) { try { Http POST "$($S.PVWA)/PasswordVault/API/Auth/Logoff" $ctx.hdr '{}' | Out-Null } catch { } }
  }
  $ok = ($ctx.Problems.Count -eq 0)
  $log | Set-Content -Path $OutFile -Encoding UTF8
  [pscustomobject]@{ Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); FailedStep = $ctx.Failed; Reason = $(if ($ok) { '' } else { $ctx.Problems[0] }); Steps = $ctx.R
                     PSMReturned = $ctx.PSMReturned; AccountId = $ctx.acctId; Screenshot = $ctx.Shot; RecordingId = $ctx.RecId; RecordingSec = $ctx.RecSec; DetailLog = $OutFile
                     Fixes = $(if ($ok) { '' } else { Get-Fixes $ctx.Failed $ctx.Problems[0] }) }
}

