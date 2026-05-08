program EchoRecorderCore;

{$mode objfpc}{$H+}

uses
  SysUtils,
  {$ifdef MSWINDOWS}
  Windows,
  {$endif}
  echo_recorder_core_api,
  echo_recorder_core_runtime;

function parseSpeechMode(const aValue: string): TSpeechMode;
begin
  if SameText(aValue, 'command') then
    Exit(smCommand);

  if SameText(aValue, 'dictation') then
    Exit(smDictation);

  raise Exception.CreateFmt('Unsupported mode: %s', [aValue]);
end;

function parseRecorderBackend(const aValue: string): TRecorderBackend;
begin
  if SameText(aValue, 'transport') then
    Exit(rbTransport);

  if SameText(aValue, 'local') or SameText(aValue, 'local-dictation') then
    Exit(rbLocalDictation);

  if SameText(aValue, 'daemon') or SameText(aValue, 'voskdaemon') then
    Exit(rbVoskDaemon);

  raise Exception.CreateFmt('Unsupported backend: %s', [aValue]);
end;

function parsePositiveInteger(const aValue: string; const aName: string): Integer;
begin
  Result := StrToIntDef(Trim(aValue), -1);
  if Result <= 0 then
    raise Exception.CreateFmt('Invalid %s: %s', [aName, aValue]);
end;

function parseInputFormat(const aValue: string): string;
begin
  Result := LowerCase(Trim(aValue));
  if (Result = 'ogg') or (Result = 'wav') or (Result = 'mp3') or (Result = 'flac') or (Result = 'pcm16le') then
    Exit;

  raise Exception.CreateFmt('Unsupported input format: %s', [aValue]);
end;

function parseDaemonKind(const aValue: string): TDaemonKind;
begin
  if SameText(aValue, 'vosk') or SameText(aValue, 'voskdaemon') then
    Exit(dkVosk);

  if SameText(aValue, 'whisper') or SameText(aValue, 'whisperdaemon') then
    Exit(dkWhisper);

  if SameText(aValue, 'diarization') or SameText(aValue, 'diarizationdaemon') then
    Exit(dkDiarization);

  if SameText(aValue, 'vibevoice') or SameText(aValue, 'vibevoicedaemon') then
    Exit(dkWhisper);

  raise Exception.CreateFmt('Unsupported daemon kind: %s', [aValue]);
end;

function inferDaemonKindFromPort(aPort: Integer): TDaemonKind;
begin
  if aPort = 7801 then
    Exit(dkWhisper);

  if aPort = 7802 then
    Exit(dkWhisper);

  if aPort = 7900 then
    Exit(dkDiarization);

  Result := dkVosk;
end;

function lastDelimiterPosition(const aValue: string; aDelimiter: Char): Integer;
var
  idx: Integer;
begin
  Result := 0;
  for idx := Length(aValue) downto 1 do
    if aValue[idx] = aDelimiter then
      Exit(idx);
end;

function firstEndpointSeparatorPosition(const aValue: string): Integer;
var
  eqPos: Integer;
  colonPos: Integer;
begin
  eqPos := Pos('=', aValue);
  colonPos := Pos(':', aValue);

  if eqPos = 0 then
    Exit(colonPos);
  if colonPos = 0 then
    Exit(eqPos);
  if eqPos < colonPos then
    Result := eqPos
  else
    Result := colonPos;
end;

procedure addDaemonEndpoint(
  var aSettings: TRecorderSettings;
  aKind: TDaemonKind;
  const aHost: string;
  aPort: Integer
);
var
  count: Integer;
begin
  count := Length(aSettings.DaemonEndpoints);
  SetLength(aSettings.DaemonEndpoints, count + 1);
  aSettings.DaemonEndpoints[count].Kind := aKind;
  aSettings.DaemonEndpoints[count].Host := Trim(aHost);
  aSettings.DaemonEndpoints[count].Port := aPort;
  aSettings.DaemonPort := aPort;
end;

procedure addDaemonPort(var aSettings: TRecorderSettings; aPort: Integer);
var
  count: Integer;
begin
  count := Length(aSettings.DaemonPorts);
  SetLength(aSettings.DaemonPorts, count + 1);
  aSettings.DaemonPorts[count] := aPort;
  aSettings.DaemonPort := aPort;
  addDaemonEndpoint(aSettings, inferDaemonKindFromPort(aPort), '', aPort);
end;

procedure parseDaemonEndpoint(
  var aSettings: TRecorderSettings;
  const aValue: string;
  const aName: string
);
var
  sep: Integer;
  lastColon: Integer;
  spec: string;
  host: string;
  kindText: string;
  portText: string;
begin
  spec := Trim(aValue);
  sep := firstEndpointSeparatorPosition(spec);
  if sep <= 1 then
    raise Exception.CreateFmt('Invalid %s: %s', [aName, aValue]);

  kindText := Trim(Copy(spec, 1, sep - 1));
  spec := Trim(Copy(spec, sep + 1, MaxInt));
  lastColon := lastDelimiterPosition(spec, ':');
  if lastColon > 0 then
  begin
    host := Trim(Copy(spec, 1, lastColon - 1));
    portText := Trim(Copy(spec, lastColon + 1, MaxInt));
  end
  else
  begin
    host := '';
    portText := spec;
  end;

  addDaemonEndpoint(
    aSettings,
    parseDaemonKind(kindText),
    host,
    parsePositiveInteger(portText, aName)
  );
end;

procedure parseDaemonPortList(
  var aSettings: TRecorderSettings;
  const aValue: string;
  const aName: string
);
var
  ch: Char;
  idx: Integer;
  part: string;
begin
  part := '';
  for idx := 1 to Length(aValue) do
  begin
    ch := aValue[idx];
    if (ch = ',') or (ch = ';') then
    begin
      if Trim(part) = '' then
        raise Exception.CreateFmt('Invalid %s: %s', [aName, aValue]);

      addDaemonPort(aSettings, parsePositiveInteger(part, aName));
      part := '';
    end
    else
      part := part + ch;
  end;

  if Trim(part) = '' then
    raise Exception.CreateFmt('Invalid %s: %s', [aName, aValue]);

  addDaemonPort(aSettings, parsePositiveInteger(part, aName));
end;

function parseLogTarget(const aArg: string; out aFormat: TRecorderLogFormat; out aPath: string): Boolean;
var
  spec: string;
  colonPos: Integer;
  formatStr: string;
begin
  aFormat := lfJsonl;
  aPath := '';
  Result := True;

  if aArg = '--log' then
    Exit;

  if (Length(aArg) < 6) or (Copy(aArg, 1, 6) <> '--log=') then
  begin
    Result := False;
    Exit;
  end;

  spec := Copy(aArg, 7, MaxInt);
  colonPos := Pos(':', spec);

  if colonPos = 0 then
  begin
    formatStr := LowerCase(Trim(spec));
    if formatStr = 'plain' then
      aFormat := lfPlain
    else if formatStr = 'jsonl' then
      aFormat := lfJsonl
    else
      raise Exception.CreateFmt('Invalid log format in %s: must be jsonl or plain', [aArg]);
    aPath := '';
  end
  else
  begin
    formatStr := LowerCase(Trim(Copy(spec, 1, colonPos - 1)));
    aPath := Trim(Copy(spec, colonPos + 1, MaxInt));
    if formatStr = 'plain' then
      aFormat := lfPlain
    else if formatStr = 'jsonl' then
      aFormat := lfJsonl
    else
      raise Exception.CreateFmt('Invalid log format in %s: must be jsonl or plain', [aArg]);
    if SameText(aPath, 'stdout') then
      aPath := '';
  end;
end;

procedure addLogTarget(var aSettings: TRecorderSettings; aFormat: TRecorderLogFormat; const aPath: string);
var
  count: Integer;
begin
  count := Length(aSettings.LogOutputs);
  SetLength(aSettings.LogOutputs, count + 1);
  aSettings.LogOutputs[count].Format := aFormat;
  aSettings.LogOutputs[count].Path := aPath;
end;

procedure requireArgValue(aIndex: Integer; const aName: string; out aValue: string);
begin
  if aIndex > ParamCount then
    raise Exception.CreateFmt('Missing value for %s', [aName]);

  aValue := ParamStr(aIndex);
end;

procedure applyCommandLine(var aSettings: TRecorderSettings; out aShowHelp: Boolean);
var
  fmt: TRecorderLogFormat;
  path: string;
  arg: string;
  val: string;
  idx: Integer;
begin
  aShowHelp := False;
  idx := 1;
  while idx <= ParamCount do
  begin
    arg := ParamStr(idx);

    if (arg = '--help') or (arg = '-h') or (arg = '/?') then
      aShowHelp := True
    else if (arg = '--input') or (arg = '-i') then
    begin
      Inc(idx);
      requireArgValue(idx, arg, val);
      aSettings.InputFilePath := val;
    end
    else if (arg = '--format') or (arg = '-f') then
    begin
      Inc(idx);
      requireArgValue(idx, arg, val);
      aSettings.InputFormat := parseInputFormat(val);
    end
    else if arg = '--tests-dir' then
    begin
      Inc(idx);
      requireArgValue(idx, '--tests-dir', val);
      aSettings.TestsDir := val;
    end
    else if arg = '--base-url' then
    begin
      Inc(idx);
      requireArgValue(idx, '--base-url', val);
      aSettings.BaseUrl := val;
    end
    else if arg = '--daemon-host' then
    begin
      Inc(idx);
      requireArgValue(idx, '--daemon-host', val);
      aSettings.DaemonHost := Trim(val);
    end
    else if arg = '--daemon-port' then
    begin
      Inc(idx);
      requireArgValue(idx, '--daemon-port', val);
      addDaemonPort(aSettings, parsePositiveInteger(val, '--daemon-port'));
    end
    else if (arg = '--daemon') or (arg = '--daemon-endpoint') then
    begin
      Inc(idx);
      requireArgValue(idx, arg, val);
      parseDaemonEndpoint(aSettings, val, arg);
    end
    else if arg = '--daemon-ports' then
    begin
      Inc(idx);
      requireArgValue(idx, '--daemon-ports', val);
      parseDaemonPortList(aSettings, val, '--daemon-ports');
    end
    else if arg = '--mode' then
    begin
      Inc(idx);
      requireArgValue(idx, '--mode', val);
      aSettings.Mode := parseSpeechMode(val);
    end
    else if arg = '--language' then
    begin
      Inc(idx);
      requireArgValue(idx, '--language', val);
      aSettings.Language := val;
    end
    else if arg = '--backend' then
    begin
      Inc(idx);
      requireArgValue(idx, '--backend', val);
      aSettings.Backend := parseRecorderBackend(val);
    end
    else if (arg = '--log') or ((Length(arg) >= 6) and (Copy(arg, 1, 6) = '--log=')) then
    begin
      parseLogTarget(arg, fmt, path);
      addLogTarget(aSettings, fmt, path);
    end
    else if arg = '--output' then
      raise Exception.Create('--output has been removed; use --log=jsonl:<file> or --log=jsonl:stdout instead')
    else if arg = '--words-only' then
      raise Exception.Create('--words-only has been removed; use --log=plain:stdout instead')
    else if (arg = '--event-log') or (arg = '--events-only') or (arg = '--events') then
      raise Exception.Create('--event-log has been removed; use --log=plain:stdout instead')
    else if arg = '--speaker-embeddings' then
      aSettings.SpeakerEmbeddings := True
    else if arg = '--no-speaker-embeddings' then
      aSettings.SpeakerEmbeddings := False
    else
      raise Exception.CreateFmt('Unknown argument: %s', [arg]);

    Inc(idx);
  end;

  { -f is required whenever -i is given; catch it here at the boundary }
  if (not aShowHelp) and (Trim(aSettings.InputFilePath) <> '') and (aSettings.InputFormat = '') then
    raise Exception.Create('-f <format> is required when -i is given');

  { inject default jsonl:stdout when no --log was specified }
  if (not aShowHelp) and (Length(aSettings.LogOutputs) = 0) then
    addLogTarget(aSettings, lfJsonl, '');

  if aShowHelp then
    Exit;

  if SameText(aSettings.InputFormat, 'pcm16le') and (Trim(aSettings.InputFilePath) <> '-') then
    raise Exception.Create('pcm16le is currently supported only with -i -');

  if SameText(aSettings.InputFormat, 'pcm16le') and
    (aSettings.Backend <> rbLocalDictation) and
    (aSettings.Backend <> rbVoskDaemon) then
    raise Exception.Create('pcm16le currently requires --backend local or --backend daemon');

  if (aSettings.Backend = rbVoskDaemon) and
    ((not SameText(aSettings.InputFormat, 'pcm16le')) or (Trim(aSettings.InputFilePath) <> '-')) then
    raise Exception.Create('--backend daemon currently supports only -f pcm16le -i -');

  if (aSettings.Backend = rbVoskDaemon) and (Trim(aSettings.DaemonHost) = '') then
    raise Exception.Create('--daemon-host cannot be empty');
end;

procedure writeUsage;
begin
  WriteLn('Usage: ', ExtractFileName(ParamStr(0)), ' [options]');
  WriteLn('  -i, --input <path|->      prerecorded audio input source');
  WriteLn('  -f, --format <value>      input format: ogg|wav|mp3|flac|pcm16le (required with -i)');
  WriteLn('      --log[=jsonl|plain][:<file|stdout>]');
  WriteLn('                            log output; may be repeated (default: jsonl:stdout)');
  WriteLn('      --speaker-embeddings  request speaker diarisation from backend (default: off)');
  WriteLn('      --no-speaker-embeddings');
  WriteLn('      --tests-dir <path>    fixture directory used when input is omitted');
  WriteLn('      --base-url <url>      EchoScript base URL, default http://127.0.0.1:3000');
  WriteLn('      --daemon-host <host>  daemon host, default 127.0.0.1');
  WriteLn('      --daemon <kind:port|kind:host:port>  daemon target, e.g. vosk:7701 or whisper:7801');
  WriteLn('      --daemon-port <port>  daemon port; may be repeated');
  WriteLn('      --daemon-ports <list> comma- or semicolon-separated daemon ports');
  WriteLn('      --mode <value>        dictation or command');
  WriteLn('      --backend <value>     transport, local-dictation, or daemon');
  WriteLn('      --language <value>    speech language, default ru');
  WriteLn('  -h, --help                show this usage text');
  WriteLn('');
  WriteLn('If input is omitted, the first .ogg fixture under tests is used.');
end;

procedure initStdin;
begin
  { Placeholder: stdin initialization if needed }
end;

var
  settings: TRecorderSettings;
  showHelp: Boolean;

begin
  initStdin;
  settings := defaultRecorderSettings;
  showHelp := False;

  try
    applyCommandLine(settings, showHelp);
    if showHelp then
    begin
      writeUsage;
      Halt(0);
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      writeUsage;
      Halt(2);
    end;
  end;

  Halt(runRecorderCli(settings));
end.
