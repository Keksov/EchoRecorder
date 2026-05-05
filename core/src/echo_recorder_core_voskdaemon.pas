unit echo_recorder_core_voskdaemon;

{$mode objfpc}{$H+}

interface

uses
  echo_recorder_core_api,
  echo_recorder_core_protocol;

function    runDaemonPcmStreamRecognition(
  const aSettings: TRecorderSettings;
  var aItem: TRecorderInputItem;
  aProtocol: TRecorderProtocolWriter
): TRecorderResult;

implementation

uses
  SysUtils,
  Windows,
  fpjson,
  fpwebsocket,
  fpwebsocketclient,
  jsonparser;

const
  PCM_STREAM_CHUNK_BYTES = 3840;
  DEFAULT_CONNECT_TIMEOUT_MS = 1500;
  DEFAULT_ACK_TIMEOUT_MS = 30000;
  DEFAULT_FINAL_TIMEOUT_MS = 120000;

type
  TVoskDaemonClientState = class
  private
    FDone                   : Boolean;
    FAckSeen                : Boolean;
    FDaemonKind             : TDaemonKind;
    FDaemonLabel            : string;
    FFinalLanguage          : string;
    FErrorText              : string;
    FFinalText              : string;
    FLastPartial            : string;
    FSegmentText            : string;
    FdetectedLanguage       : string;
    FspeakerCount           : Integer;
    FspeakerSegments        : TRecorderSpeakerSegments;
    FProtocol               : TRecorderProtocolWriter;
    FSettings               : TRecorderSettings;
    FItem                   : TRecorderInputItem;
    procedure   appendTextWithSpace(var aTarget: string; const aValue: string);
    procedure   parseSpeakerSegments(const aRoot: TJSONObject);
    function    jsonFloatOf(const aObject: TJSONObject; const aName: string; out aValue: Double): Boolean;
    function    jsonInt64Of(const aObject: TJSONObject; const aName: string): Int64;
    function    jsonStringOf(const aObject: TJSONObject; const aName: string): string;
    procedure   setError(const aMessage: string);
  public
    constructor Create(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem;
      aDaemonKind: TDaemonKind;
      const aDaemonLabel: string;
      aProtocol: TRecorderProtocolWriter
    );
    procedure   handleDisconnect(Sender: TObject);
    procedure   handleMessage(Sender: TObject; const aMessage: TWSMessage);
    property    AckSeen: Boolean read FAckSeen;
    property    Done: Boolean read FDone;
    property    ErrorText: string read FErrorText;
    property    FinalLanguage: string read FFinalLanguage;
    property    FinalText: string read FFinalText;
    property    DetectedLanguage: string read FdetectedLanguage;
    property    SpeakerCount: Integer read FspeakerCount;
    property    SpeakerSegments: TRecorderSpeakerSegments read FspeakerSegments;
  end;

  TDaemonClientContext = record
    Kind: TDaemonKind;
    Host: string;
    Port: Integer;
    LabelText: string;
    Client: TWebsocketClient;
    State: TVoskDaemonClientState;
  end;

  TDaemonClientContexts = array of TDaemonClientContext;

function resolveDaemonHost(const aSettings: TRecorderSettings): string;
begin
  Result := Trim(aSettings.DaemonHost);
  if Result = '' then
    Result := '127.0.0.1';
end;

function resolveDaemonPort(const aSettings: TRecorderSettings): Integer;
begin
  if aSettings.DaemonPort > 0 then
    Exit(aSettings.DaemonPort);

  Result := defaultVoskDaemonPort(aSettings);
end;

function inferDaemonKindFromPort(aPort: Integer): TDaemonKind;
begin
  if aPort = 7801 then
    Exit(dkWhisper);

  Result := dkVosk;
end;

function resolveEndpointHost(const aSettings: TRecorderSettings; const aEndpoint: TDaemonEndpoint): string;
begin
  Result := Trim(aEndpoint.Host);
  if Result = '' then
    Result := resolveDaemonHost(aSettings);
end;

function resolveDaemonEndpoints(const aSettings: TRecorderSettings): TDaemonEndpoints;
var
  idx: Integer;
begin
  if Length(aSettings.DaemonEndpoints) > 0 then
  begin
    SetLength(Result, Length(aSettings.DaemonEndpoints));
    for idx := 0 to High(aSettings.DaemonEndpoints) do
      Result[idx] := aSettings.DaemonEndpoints[idx];
    Exit;
  end;

  if Length(aSettings.DaemonPorts) > 0 then
  begin
    SetLength(Result, Length(aSettings.DaemonPorts));
    for idx := 0 to High(aSettings.DaemonPorts) do
    begin
      Result[idx].Kind := inferDaemonKindFromPort(aSettings.DaemonPorts[idx]);
      Result[idx].Host := '';
      Result[idx].Port := aSettings.DaemonPorts[idx];
    end;
    Exit;
  end;

  SetLength(Result, 1);
  Result[0].Host := '';
  Result[0].Port := resolveDaemonPort(aSettings);
  Result[0].Kind := inferDaemonKindFromPort(Result[0].Port);
end;

function daemonLabelOf(aKind: TDaemonKind; const aHost: string; aPort: Integer): string;
begin
  Result := daemonKindLabel(aKind) + '@' + aHost + ':' + IntToStr(aPort);
end;

function buildSessionStartMessage(
  const aSettings: TRecorderSettings;
  aDaemonKind: TDaemonKind
): string;
var
  root: TJSONObject;
begin
  root := TJSONObject.Create;
  try
    root.Add('event', 'session_start');
    root.Add('audio_format', 'pcm16le');
    root.Add('sample_rate_hz', 16000);
    root.Add('channels', 1);
    root.Add('sample_format', 's16le');
    root.Add('language', aSettings.Language);
    root.Add('mode', speechModeLabel(aSettings.Mode));
    root.Add('speaker_embeddings', aSettings.SpeakerEmbeddings);
    root.Add('emit_partials', aDaemonKind = dkVosk);
    root.Add('emit_words', True);
    Result := root.AsJSON;
  finally
    root.Free;
  end;
end;

function buildFlushMessage: string;
var
  root: TJSONObject;
begin
  root := TJSONObject.Create;
  try
    root.Add('event', 'flush');
    Result := root.AsJSON;
  finally
    root.Free;
  end;
end;

procedure drainIncoming(aClient: TWebsocketClient);
var
  resultCode: TIncomingResult;
begin
  repeat
    resultCode := aClient.CheckIncoming;
    if resultCode in [irNone, irWaiting, irClose] then
      Break;
  until False;
end;

procedure drainClients(var aClients: TDaemonClientContexts);
var
  idx: Integer;
begin
  for idx := 0 to High(aClients) do
    if aClients[idx].Client <> nil then
      drainIncoming(aClients[idx].Client);
end;

procedure checkClientErrors(const aClients: TDaemonClientContexts);
var
  idx: Integer;
begin
  for idx := 0 to High(aClients) do
    if (aClients[idx].State <> nil) and (aClients[idx].State.ErrorText <> '') then
      raise Exception.CreateFmt('%s: %s', [aClients[idx].LabelText, aClients[idx].State.ErrorText]);
end;

function allClientsAckSeen(const aClients: TDaemonClientContexts): Boolean;
var
  idx: Integer;
begin
  Result := True;
  for idx := 0 to High(aClients) do
    if (aClients[idx].State = nil) or (not aClients[idx].State.AckSeen) then
      Exit(False);
end;

function allClientsDone(const aClients: TDaemonClientContexts): Boolean;
var
  idx: Integer;
begin
  Result := True;
  for idx := 0 to High(aClients) do
    if (aClients[idx].State = nil) or (not aClients[idx].State.Done) then
      Exit(False);
end;

procedure waitForClientsState(
  const aWhat: string;
  aTimeoutMs: Integer;
  var aClients: TDaemonClientContexts;
  aNeedAck: Boolean;
  aNeedDone: Boolean
);
var
  nowTick: QWord;
  endTick: QWord;
begin
  endTick := GetTickCount64 + QWord(aTimeoutMs);
  repeat
    drainClients(aClients);
    checkClientErrors(aClients);

    if aNeedAck and allClientsAckSeen(aClients) then
      Exit;
    if aNeedDone and allClientsDone(aClients) then
      Exit;

    nowTick := GetTickCount64;
    if nowTick >= endTick then
      raise Exception.CreateFmt('Timed out waiting for daemon %s', [aWhat]);

    Sleep(10);
  until False;
end;

constructor TVoskDaemonClientState.Create(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  aDaemonKind: TDaemonKind;
  const aDaemonLabel: string;
  aProtocol: TRecorderProtocolWriter
);
begin
  inherited Create;
  FDone := False;
  FAckSeen := False;
  FDaemonKind := aDaemonKind;
  FDaemonLabel := aDaemonLabel;
  FFinalLanguage := '';
  FErrorText := '';
  FFinalText := '';
  FLastPartial := '';
  FSegmentText := '';
  FdetectedLanguage := '';
  FspeakerCount := 0;
  SetLength(FspeakerSegments, 0);
  FProtocol := aProtocol;
  FSettings := aSettings;
  FItem := aItem;
end;

procedure TVoskDaemonClientState.parseSpeakerSegments(const aRoot: TJSONObject);
var
  arr: TJSONArray;
  obj: TJSONObject;
  idx: Integer;
  data: TJSONData;
begin
  FspeakerCount := Integer(jsonInt64Of(aRoot, 'speaker_count'));
  SetLength(FspeakerSegments, 0);

  if aRoot = nil then
    Exit;

  data := aRoot.Find('speaker_segments');
  if (data = nil) or (data.JSONType <> jtArray) then
    Exit;

  arr := TJSONArray(data);
  SetLength(FspeakerSegments, arr.Count);
  for idx := 0 to arr.Count - 1 do
  begin
    if arr.Items[idx].JSONType <> jtObject then
      Continue;

    obj := TJSONObject(arr.Items[idx]);
    FspeakerSegments[idx].SegmentId := Integer(jsonInt64Of(obj, 'segment_id'));
    FspeakerSegments[idx].StartMs := jsonInt64Of(obj, 'start_ms');
    FspeakerSegments[idx].EndMs := jsonInt64Of(obj, 'end_ms');
    FspeakerSegments[idx].SpeakerId := Trim(jsonStringOf(obj, 'speaker_id'));
    FspeakerSegments[idx].Text := Trim(jsonStringOf(obj, 'text'));
  end;
end;

procedure TVoskDaemonClientState.appendTextWithSpace(var aTarget: string; const aValue: string);
var
  value: string;
begin
  value := Trim(aValue);
  if value = '' then
    Exit;

  if aTarget = '' then
    aTarget := value
  else
    aTarget := aTarget + ' ' + value;
end;

function TVoskDaemonClientState.jsonFloatOf(const aObject: TJSONObject; const aName: string; out aValue: Double): Boolean;
var
  data: TJSONData;
begin
  Result := False;
  aValue := 0;
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data = nil) or (data.JSONType = jtNull) then
    Exit;

  try
    aValue := data.AsFloat;
    Result := True;
  except
    Result := False;
  end;
end;

function TVoskDaemonClientState.jsonInt64Of(const aObject: TJSONObject; const aName: string): Int64;
var
  data: TJSONData;
begin
  Result := 0;
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data = nil) or (data.JSONType = jtNull) then
    Exit;

  Result := data.AsInt64;
end;

function TVoskDaemonClientState.jsonStringOf(const aObject: TJSONObject; const aName: string): string;
var
  data: TJSONData;
begin
  Result := '';
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data <> nil) and (data.JSONType <> jtNull) then
    Result := data.AsString;
end;

procedure TVoskDaemonClientState.setError(const aMessage: string);
begin
  if FErrorText = '' then
    FErrorText := Trim(aMessage);
  FDone := True;
end;

procedure TVoskDaemonClientState.handleDisconnect(Sender: TObject);
begin
  if (not FDone) and (FErrorText = '') then
    setError('Disconnected from ' + FDaemonLabel + ' before session_final');
end;

procedure TVoskDaemonClientState.handleMessage(Sender: TObject; const aMessage: TWSMessage);
var
  data: TJSONData;
  root: TJSONObject;
  endMs: Int64;
  eventName: string;
  startMs: Int64;
  segmentId: Integer;
  text: string;
  confidence: Double;
begin
  if not aMessage.IsText then
    Exit;

  data := GetJSON(aMessage.AsString);
  try
    if data.JSONType <> jtObject then
      Exit;

    root := TJSONObject(data);
    eventName := LowerCase(Trim(jsonStringOf(root, 'event')));

    if eventName = 'session_ack' then
    begin
      FAckSeen := True;
      Exit;
    end;

    if eventName = 'partial_update' then
    begin
      if FDaemonKind <> dkVosk then
        Exit;

      text := Trim(jsonStringOf(root, 'text'));
      if (text <> '') and (text <> FLastPartial) then
      begin
        if FProtocol <> nil then
          FProtocol.writeLocalPartial(
            FItem,
            text,
            jsonInt64Of(root, 'start_ms'),
            jsonInt64Of(root, 'end_ms'),
            FDaemonLabel
          );
        FLastPartial := text;
      end;
      Exit;
    end;

    if eventName = 'word_committed' then
    begin
      text := Trim(jsonStringOf(root, 'text'));
      if (text <> '') and (FProtocol <> nil) then
      begin
        confidence := 0;
        if not jsonFloatOf(root, 'confidence', confidence) then
          jsonFloatOf(root, 'p', confidence);
        segmentId := Integer(jsonInt64Of(root, 'segment_id'));
        FProtocol.writeWordCommitted(
          FItem,
          text,
          jsonInt64Of(root, 'start_ms'),
          jsonInt64Of(root, 'end_ms'),
          confidence,
          segmentId,
          FDaemonLabel
        );
      end;
      Exit;
    end;

    if eventName = 'segment_final' then
    begin
      text := Trim(jsonStringOf(root, 'text'));
      if text <> '' then
        appendTextWithSpace(FSegmentText, text);

      if (text <> '') and (FProtocol <> nil) then
      begin
        startMs := jsonInt64Of(root, 'start_ms');
        endMs := jsonInt64Of(root, 'end_ms');
        if (startMs = 0) and (root.Find('t0_ms') <> nil) then
          startMs := jsonInt64Of(root, 't0_ms');
        if (endMs = 0) and (root.Find('t1_ms') <> nil) then
          endMs := jsonInt64Of(root, 't1_ms');
        segmentId := Integer(jsonInt64Of(root, 'segment_id'));
        FProtocol.writeSegmentFinal(
          FItem,
          text,
          startMs,
          endMs,
          segmentId,
          FDaemonLabel
        );
      end;
      FLastPartial := '';
      Exit;
    end;

    if eventName = 'session_final' then
    begin
      FFinalText := Trim(jsonStringOf(root, 'text'));
      FFinalLanguage := Trim(jsonStringOf(root, 'language'));
      FdetectedLanguage := Trim(jsonStringOf(root, 'detected_language'));
      parseSpeakerSegments(root);
      if (FFinalLanguage = '') and (FdetectedLanguage <> '') then
        FFinalLanguage := FdetectedLanguage;
      if (FFinalText = '') and (FSegmentText <> '') then
        FFinalText := FSegmentText;
      FDone := True;
      Exit;
    end;

    if (eventName = 'error') or (eventName = 'busy') then
    begin
      setError(jsonStringOf(root, 'message'));
      Exit;
    end;

    if eventName = 'warning' then
    begin
      WriteLn(StdErr, '[daemon] warning: ', jsonStringOf(root, 'message'));
      Exit;
    end;
  finally
    data.Free;
  end;
end;

procedure freeDaemonClients(var aClients: TDaemonClientContexts);
var
  idx: Integer;
begin
  for idx := 0 to High(aClients) do
  begin
    aClients[idx].Client.Free;
    aClients[idx].State.Free;
    aClients[idx].Client := nil;
    aClients[idx].State := nil;
  end;
  SetLength(aClients, 0);
end;

procedure connectDaemonClients(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  aProtocol: TRecorderProtocolWriter;
  var aClients: TDaemonClientContexts
);
var
  idx: Integer;
  host: string;
  endpoints: TDaemonEndpoints;
begin
  endpoints := resolveDaemonEndpoints(aSettings);
  if Length(endpoints) = 0 then
    raise Exception.Create('No daemon endpoints resolved');

  SetLength(aClients, Length(endpoints));
  try
    for idx := 0 to High(endpoints) do
    begin
      if endpoints[idx].Port <= 0 then
        raise Exception.Create('Daemon endpoint port must be positive');

      host := resolveEndpointHost(aSettings, endpoints[idx]);
      aClients[idx].Kind := endpoints[idx].Kind;
      aClients[idx].Host := host;
      aClients[idx].Port := endpoints[idx].Port;
      aClients[idx].LabelText := daemonLabelOf(endpoints[idx].Kind, host, endpoints[idx].Port);
      aClients[idx].Client := TWebsocketClient.Create(nil);
      aClients[idx].State := TVoskDaemonClientState.Create(
        aSettings,
        aItem,
        endpoints[idx].Kind,
        aClients[idx].LabelText,
        aProtocol
      );
      aClients[idx].Client.ConnectTimeout := DEFAULT_CONNECT_TIMEOUT_MS;
      aClients[idx].Client.CheckTimeout := 50;
      aClients[idx].Client.HostName := host;
      aClients[idx].Client.Port := endpoints[idx].Port;
      aClients[idx].Client.Resource := '/';
      aClients[idx].Client.OnMessageReceived := @aClients[idx].State.handleMessage;
      aClients[idx].Client.OnDisconnect := @aClients[idx].State.handleDisconnect;
      aClients[idx].Client.Connect;
      aClients[idx].Client.SendMessage(buildSessionStartMessage(aSettings, endpoints[idx].Kind));
    end;

    waitForClientsState('session_ack', DEFAULT_ACK_TIMEOUT_MS, aClients, True, False);
  except
    freeDaemonClients(aClients);
    raise;
  end;
end;

procedure sendDataToClients(var aClients: TDaemonClientContexts; const aChunkBytes: TBytes);
var
  idx: Integer;
begin
  for idx := 0 to High(aClients) do
    aClients[idx].Client.SendData(aChunkBytes);
  drainClients(aClients);
  checkClientErrors(aClients);
end;

procedure sendFlushToClients(var aClients: TDaemonClientContexts);
var
  idx: Integer;
  messageText: string;
begin
  messageText := buildFlushMessage;
  for idx := 0 to High(aClients) do
    aClients[idx].Client.SendMessage(messageText);
end;

function buildDaemonAggregateText(const aClients: TDaemonClientContexts): string;
var
  idx: Integer;
  line: string;
  text: string;
begin
  Result := '';
  if Length(aClients) = 1 then
  begin
    if aClients[0].State <> nil then
      Result := aClients[0].State.FinalText;
    Exit;
  end;

  for idx := 0 to High(aClients) do
  begin
    text := '';
    if aClients[idx].State <> nil then
      text := Trim(aClients[idx].State.FinalText);
    if text = '' then
      Continue;

    line := '[' + aClients[idx].LabelText + '] ' + text;
    if Result = '' then
      Result := line
    else
      Result := Result + LineEnding + line;
  end;
end;

procedure writeDaemonServerFinals(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  const aClients: TDaemonClientContexts;
  aProtocol: TRecorderProtocolWriter
);
var
  idx: Integer;
  resultData: TRecorderResult;
begin
  if aProtocol = nil then
    Exit;

  for idx := 0 to High(aClients) do
  begin
    resultData := emptyRecorderResult;
    resultData.Ok := True;
    resultData.StatusCode := 200;
    resultData.ModeName := speechModeLabel(aSettings.Mode);
    resultData.Language := aSettings.Language;
    resultData.InputPath := aItem.FilePath;
    resultData.BackendName := recorderBackendLabel(rbVoskDaemon);
    resultData.TargetModel := aClients[idx].LabelText;
    if aClients[idx].State <> nil then
    begin
      if aClients[idx].State.FinalLanguage <> '' then
        resultData.Language := aClients[idx].State.FinalLanguage;
      resultData.DetectedLanguage := aClients[idx].State.DetectedLanguage;
      resultData.Text := aClients[idx].State.FinalText;
      resultData.RawText := aClients[idx].State.FinalText;
      resultData.NormalizedText := aClients[idx].State.FinalText;
      resultData.SpeakerCount := aClients[idx].State.SpeakerCount;
      resultData.SpeakerSegments := aClients[idx].State.SpeakerSegments;
    end;
    aProtocol.writeServerFinal(aSettings, aItem, resultData, idx + 1, Length(aClients));
  end;
end;

function runDaemonPcmStreamRecognition(
  const aSettings: TRecorderSettings;
  var aItem: TRecorderInputItem;
  aProtocol: TRecorderProtocolWriter
): TRecorderResult;
var
  ok: BOOL;
  idx: Integer;
  err: DWORD;
  len: DWORD;
  read: DWORD;
  carry: Byte;
  carryLen: Integer;
  totalBytes: Int64;
  chunkBytes: TBytes;
  clients: TDaemonClientContexts;
  stdinHandle: THandle;
  chunkData: array[0..PCM_STREAM_CHUNK_BYTES] of Byte;
begin
  Result := emptyRecorderResult;
  Result.Ok := True;
  Result.StatusCode := 200;
  Result.ModeName := speechModeLabel(aSettings.Mode);
  Result.Language := aSettings.Language;
  Result.InputPath := aItem.FilePath;
  Result.BackendName := recorderBackendLabel(rbVoskDaemon);

  stdinHandle := GetStdHandle(STD_INPUT_HANDLE);
  if stdinHandle = INVALID_HANDLE_VALUE then
    raise Exception.Create('Failed to get stdin handle');

  carry := 0;
  read := 0;
  carryLen := 0;
  totalBytes := 0;
  clients := nil;
  try
    connectDaemonClients(aSettings, aItem, aProtocol, clients);

    repeat
      if carryLen > 0 then
        chunkData[0] := carry;

      read := 0;
      ok := Windows.ReadFile(
        stdinHandle,
        chunkData[carryLen],
        PCM_STREAM_CHUNK_BYTES - carryLen,
        read,
        nil
      );
      len := read + DWORD(carryLen);

      if len > 0 then
      begin
        if (len mod SizeOf(SmallInt)) <> 0 then
        begin
          carry := chunkData[len - 1];
          carryLen := 1;
          Dec(len);
        end
        else
          carryLen := 0;

        if len > 0 then
        begin
          SetLength(chunkBytes, len);
          Move(chunkData[0], chunkBytes[0], len);
          sendDataToClients(clients, chunkBytes);
          Inc(totalBytes, len);
        end;
      end;

      if ok and (read = 0) then
        Break;

      if not ok then
      begin
        err := GetLastError();
        if (err = ERROR_BROKEN_PIPE) or (err = ERROR_HANDLE_EOF) then
          Break;

        raise Exception.CreateFmt('Failed to read pcm16le stdin: %d', [err]);
      end;
    until False;

    if carryLen <> 0 then
      raise Exception.Create('PCM16LE stdin ended on an odd byte boundary');

    aItem.SizeBytes := totalBytes;
    sendFlushToClients(clients);
    waitForClientsState('session_final', DEFAULT_FINAL_TIMEOUT_MS, clients, False, True);
    checkClientErrors(clients);
    writeDaemonServerFinals(aSettings, aItem, clients, aProtocol);

    Result.TargetModel := 'multi-daemon';
    if Length(clients) = 1 then
      Result.TargetModel := clients[0].LabelText;
    for idx := 0 to High(clients) do
    begin
      if clients[idx].State = nil then
        Continue;
      if (Result.Language = aSettings.Language) and (clients[idx].State.FinalLanguage <> '') then
        Result.Language := clients[idx].State.FinalLanguage;
      if (Result.DetectedLanguage = '') and (clients[idx].State.DetectedLanguage <> '') then
        Result.DetectedLanguage := clients[idx].State.DetectedLanguage;
      if (Result.SpeakerCount = 0) and (clients[idx].State.SpeakerCount > 0) then
        Result.SpeakerCount := clients[idx].State.SpeakerCount;
      if (Length(Result.SpeakerSegments) = 0) and (Length(clients[idx].State.SpeakerSegments) > 0) then
        Result.SpeakerSegments := clients[idx].State.SpeakerSegments;
    end;
    Result.Text := buildDaemonAggregateText(clients);
    Result.RawText := Result.Text;
    Result.NormalizedText := Result.Text;
  finally
    freeDaemonClients(clients);
  end;
end;

end.