unit echo_recorder_core_protocol;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  fpjson,
  echo_recorder_core_api;

type
  TLogOutputEntry = record
    stream              : TFileStream;
    format              : TRecorderLogFormat;
  end;
  TLogOutputEntries = array of TLogOutputEntry;

  TRecorderProtocolWriter = class
  private
    FrunId              : string;
    Fseq                : Int64;
    FhasJsonl           : Boolean;
    FhasPlain           : Boolean;
    Fentries            : TLogOutputEntries;
    function    currentTimestampMs: Int64;
    function    escapeEventText(const aText: string): string;
    function    nextSeq: Int64;
    function    sourceKindOf(const aItem: TRecorderInputItem): string;
    function    buildEventLine(const aEvent: string; const aEndpoint: string; const aText: string; aSeq: Int64): string;
    function    newEventObject(const aEvent: string; aSeq: Int64): TJSONObject;
    procedure   writePlainLine(const aLine: string);
    procedure   writeJsonlLine(const aLine: string);
  public
    constructor Create(const aLogOutputs: TRecorderLogOutputs);
    destructor  Destroy; override;
    procedure   writeAccepted(const aSettings: TRecorderSettings);
    procedure   writeSource(const aItem: TRecorderInputItem);
    procedure   writeBackendStarted(
      const aSettings: TRecorderSettings;
      aFragmentIndex: Integer;
      aFragmentCount: Integer
    );
    procedure   writeBackendProgress(
      const aSettings: TRecorderSettings;
      aFragmentIndex: Integer;
      aFragmentCount: Integer;
      aCompletedFragments: Integer;
      aSubmittedBytes: Int64
    );
    procedure   writeLocalPartial(
      const aItem: TRecorderInputItem;
      const aText: string;
      aStartMs: Int64;
      aEndMs: Int64;
      const aDaemonLabel: string = ''
    );
    procedure   writeWordCommitted(
      const aItem: TRecorderInputItem;
      const aWord: string;
      aStartMs: Int64;
      aEndMs: Int64;
      aConfidence: Double;
      aSegmentId: Integer;
      const aDaemonLabel: string = ''
    );
    procedure   writeSegmentFinal(
      const aItem: TRecorderInputItem;
      const aText: string;
      aStartMs: Int64;
      aEndMs: Int64;
      aSegmentId: Integer;
      const aDaemonLabel: string = ''
    );
    procedure   writeServerFinal(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem;
      const aResult: TRecorderResult;
      aFragmentIndex: Integer;
      aFragmentCount: Integer
    );
    procedure   writeFinal(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem;
      const aResult: TRecorderResult
    );
    procedure   writeError(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem;
      const aStage: string;
      const aMessage: string;
      aStatusCode: Integer = 0
    );
  end;

implementation

uses
  JsonLineProtocol;

procedure addSpeakerSegments(root: TJSONObject; const aSegments: TRecorderSpeakerSegments);
var
  arr: TJSONArray;
  idx: Integer;
  item: TJSONObject;
begin
  if Length(aSegments) = 0 then
    Exit;

  arr := TJSONArray.Create;
  for idx := 0 to High(aSegments) do
  begin
    item := TJSONObject.Create;
    item.Add('segment_id', aSegments[idx].SegmentId);
    item.Add('start_ms', aSegments[idx].StartMs);
    item.Add('end_ms', aSegments[idx].EndMs);
    item.Add('speaker_id', aSegments[idx].SpeakerId);
    if aSegments[idx].Text <> '' then
      item.Add('text', aSegments[idx].Text);
    arr.Add(item);
  end;

  root.Add('speaker_segments', arr);
end;

function makeRunId: string;
begin
  Result := FormatDateTime('yyyymmddhhnnsszzz', Now) + '-' + IntToHex(Random($7fffffff), 8);
end;

constructor TRecorderProtocolWriter.Create(const aLogOutputs: TRecorderLogOutputs);
var
  idx: Integer;
  count: Integer;
  dir: string;
begin
  inherited Create;
  FrunId := makeRunId;
  Fseq := 0;
  FhasJsonl := False;
  FhasPlain := False;
  count := Length(aLogOutputs);
  SetLength(Fentries, count);
  for idx := 0 to count - 1 do
  begin
    Fentries[idx].format := aLogOutputs[idx].Format;
    if aLogOutputs[idx].Format = lfJsonl then
      FhasJsonl := True
    else
      FhasPlain := True;
    if Trim(aLogOutputs[idx].Path) = '' then
      Fentries[idx].stream := nil
    else
    begin
      dir := ExtractFileDir(ExpandFileName(aLogOutputs[idx].Path));
      if (dir <> '') and (not DirectoryExists(dir)) then
        ForceDirectories(dir);
      Fentries[idx].stream := TFileStream.Create(aLogOutputs[idx].Path, fmCreate);
    end;
  end;
end;

function TRecorderProtocolWriter.escapeEventText(const aText: string): string;
begin
  Result := Trim(aText);
  Result := StringReplace(Result, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
end;

destructor TRecorderProtocolWriter.Destroy;
var
  idx: Integer;
begin
  for idx := 0 to Length(Fentries) - 1 do
    Fentries[idx].stream.Free;
  inherited Destroy;
end;

function TRecorderProtocolWriter.currentTimestampMs: Int64;
const
  MILLIS_PER_DAY = 24 * 60 * 60 * 1000;
var
  epoch: TDateTime;
begin
  epoch := EncodeDate(1970, 1, 1);
  Result := Round((Now - epoch) * MILLIS_PER_DAY);
end;

function TRecorderProtocolWriter.nextSeq: Int64;
begin
  Inc(Fseq);
  Result := Fseq;
end;

function TRecorderProtocolWriter.sourceKindOf(const aItem: TRecorderInputItem): string;
begin
  if aItem.FilePath = '<<STDIN>>' then
    Exit('stdin');

  Result := 'file';
end;

function TRecorderProtocolWriter.newEventObject(const aEvent: string; aSeq: Int64): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('v', 1);
  Result.Add('schema_version', 2);
  Result.Add('event', aEvent);
  Result.Add('seq', aSeq);
  Result.Add('run_id', FrunId);
  Result.Add('ts_ms', currentTimestampMs);
end;

procedure TRecorderProtocolWriter.writePlainLine(const aLine: string);
var
  idx: Integer;
  data: UTF8String;
begin
  data := UTF8String(aLine + LineEnding);
  for idx := 0 to Length(Fentries) - 1 do
  begin
    if Fentries[idx].format <> lfPlain then
      Continue;
    if Fentries[idx].stream = nil then
      writeStdoutLine(aLine)
    else if Length(data) > 0 then
      Fentries[idx].stream.WriteBuffer(data[1], Length(data));
  end;
end;

procedure TRecorderProtocolWriter.writeJsonlLine(const aLine: string);
var
  idx: Integer;
  data: UTF8String;
begin
  data := UTF8String(aLine + LineEnding);
  for idx := 0 to Length(Fentries) - 1 do
  begin
    if Fentries[idx].format <> lfJsonl then
      Continue;
    if Fentries[idx].stream = nil then
      writeStdoutLine(aLine)
    else if Length(data) > 0 then
      Fentries[idx].stream.WriteBuffer(data[1], Length(data));
  end;
end;

function TRecorderProtocolWriter.buildEventLine(const aEvent: string; const aEndpoint: string; const aText: string; aSeq: Int64): string;
var
  line: string;
  text: string;
  endpoint: string;
begin
  line := 'seq=' + IntToStr(aSeq);
  if aSeq < 10 then
    line := line + ' ';

  line := line + ' ' + aEvent;
  if Length(aEvent) < 14 then
    line := line + StringOfChar(' ', 14 - Length(aEvent));

  endpoint := Trim(aEndpoint);
  if endpoint <> '' then
    line := line + ' ' + endpoint;

  text := escapeEventText(aText);
  if text <> '' then
    line := line + ' "' + text + '"';

  Result := line;
end;

procedure TRecorderProtocolWriter.writeAccepted(const aSettings: TRecorderSettings);
var
  seq: Int64;
  root: TJSONObject;
begin
  if (not FhasJsonl) and (not FhasPlain) then
    Exit;

  seq := nextSeq;

  if FhasPlain then
    writePlainLine(buildEventLine(
      'accepted',
      recorderBackendLabel(aSettings.Backend),
      speechModeLabel(aSettings.Mode) + ' ' + aSettings.Language,
      seq
    ));

  if FhasJsonl then
  begin
    root := newEventObject('accepted', seq);
    try
      root.Add('backend', recorderBackendLabel(aSettings.Backend));
      root.Add('mode', speechModeLabel(aSettings.Mode));
      root.Add('language', aSettings.Language);
      root.Add('input_format', aSettings.InputFormat);
      root.Add('speaker_embeddings', aSettings.SpeakerEmbeddings);
      writeJsonlLine(root.AsJSON);
    finally
      root.Free;
    end;
  end;
end;

procedure TRecorderProtocolWriter.writeSource(const aItem: TRecorderInputItem);
var
  seq: Int64;
  inputPath: string;
  root: TJSONObject;
begin
  if (not FhasJsonl) and (not FhasPlain) then
    Exit;

  seq := nextSeq;
  inputPath := aItem.FilePath;
  if inputPath = '<<STDIN>>' then
    inputPath := '-';

  if FhasPlain then
    writePlainLine(buildEventLine('source', sourceKindOf(aItem), inputPath, seq));

  if FhasJsonl then
  begin
    root := newEventObject('source', seq);
    try
      root.Add('source_kind', sourceKindOf(aItem));
      root.Add('display_name', aItem.DisplayName);
      root.Add('file_name', aItem.FileName);
      root.Add('input_path', inputPath);
      root.Add('size_bytes', aItem.SizeBytes);
      writeJsonlLine(root.AsJSON);
    finally
      root.Free;
    end;
  end;
end;

procedure TRecorderProtocolWriter.writeBackendStarted(
  const aSettings: TRecorderSettings;
  aFragmentIndex: Integer;
  aFragmentCount: Integer
);
var
  seq: Int64;
  root: TJSONObject;
begin
  if (not FhasJsonl) and (not FhasPlain) then
    Exit;

  seq := nextSeq;

  if FhasPlain then
    writePlainLine(buildEventLine(
      'backend_started',
      recorderBackendLabel(aSettings.Backend),
      IntToStr(aFragmentIndex) + '/' + IntToStr(aFragmentCount),
      seq
    ));

  if FhasJsonl then
  begin
    root := newEventObject('backend_started', seq);
    try
      root.Add('backend', recorderBackendLabel(aSettings.Backend));
      root.Add('mode', speechModeLabel(aSettings.Mode));
      root.Add('fragment_index', aFragmentIndex);
      if aFragmentCount > 0 then
        root.Add('fragment_count', aFragmentCount);
      writeJsonlLine(root.AsJSON);
    finally
      root.Free;
    end;
  end;
end;

procedure TRecorderProtocolWriter.writeBackendProgress(
  const aSettings: TRecorderSettings;
  aFragmentIndex: Integer;
  aFragmentCount: Integer;
  aCompletedFragments: Integer;
  aSubmittedBytes: Int64
);
var
  seq: Int64;
  progressPct: Integer;
  root: TJSONObject;
begin
  if (not FhasJsonl) and (not FhasPlain) then
    Exit;

  seq := nextSeq;
  progressPct := 0;
  if aFragmentCount > 0 then
    progressPct := Round((aCompletedFragments * 100.0) / aFragmentCount);

  if FhasPlain then
    writePlainLine(buildEventLine(
      'backend_progress',
      recorderBackendLabel(aSettings.Backend),
      IntToStr(progressPct) + '% bytes=' + IntToStr(aSubmittedBytes),
      seq
    ));

  if FhasJsonl then
  begin
    root := newEventObject('backend_progress', seq);
    try
      root.Add('backend', recorderBackendLabel(aSettings.Backend));
      root.Add('fragment_index', aFragmentIndex);
      root.Add('fragment_count', aFragmentCount);
      root.Add('completed_fragments', aCompletedFragments);
      root.Add('submitted_bytes', aSubmittedBytes);
      root.Add('progress_pct', progressPct);
      writeJsonlLine(root.AsJSON);
    finally
      root.Free;
    end;
  end;
end;

procedure TRecorderProtocolWriter.writeLocalPartial(
  const aItem: TRecorderInputItem;
  const aText: string;
  aStartMs: Int64;
  aEndMs: Int64;
  const aDaemonLabel: string
);
var
  seq: Int64;
  root: TJSONObject;
begin
  if (not FhasJsonl) and (not FhasPlain) then
    Exit;

  seq := nextSeq;

  if FhasPlain then
    writePlainLine(buildEventLine('local_partial', aDaemonLabel, aText, seq));

  if FhasJsonl then
  begin
    root := newEventObject('local_partial', seq);
    try
      root.Add('source_kind', sourceKindOf(aItem));
      root.Add('text', aText);
      root.Add('start_ms', aStartMs);
      root.Add('end_ms', aEndMs);
      if aDaemonLabel <> '' then
        root.Add('daemon_endpoint', aDaemonLabel);
      writeJsonlLine(root.AsJSON);
    finally
      root.Free;
    end;
  end;
end;

procedure TRecorderProtocolWriter.writeWordCommitted(
  const aItem: TRecorderInputItem;
  const aWord: string;
  aStartMs: Int64;
  aEndMs: Int64;
  aConfidence: Double;
  aSegmentId: Integer;
  const aDaemonLabel: string
);
var
  seq: Int64;
  word: string;
  root: TJSONObject;
begin
  if not FhasJsonl then
    Exit;

  word := Trim(aWord);
  if word = '' then
    Exit;

  seq := nextSeq;

  root := newEventObject('word_committed', seq);
  try
    root.Add('source_kind', sourceKindOf(aItem));
    root.Add('text', word);
    root.Add('start_ms', aStartMs);
    root.Add('end_ms', aEndMs);
    root.Add('confidence', aConfidence);
    root.Add('segment_id', aSegmentId);
    if aDaemonLabel <> '' then
      root.Add('daemon_endpoint', aDaemonLabel);
    writeJsonlLine(root.AsJSON);
  finally
    root.Free;
  end;
end;

procedure TRecorderProtocolWriter.writeSegmentFinal(
  const aItem: TRecorderInputItem;
  const aText: string;
  aStartMs: Int64;
  aEndMs: Int64;
  aSegmentId: Integer;
  const aDaemonLabel: string
);
var
  seq: Int64;
  text: string;
  root: TJSONObject;
begin
  if (not FhasJsonl) and (not FhasPlain) then
    Exit;

  text := Trim(aText);
  if text = '' then
    Exit;

  seq := nextSeq;

  if FhasPlain then
    writePlainLine(buildEventLine('segment_final', aDaemonLabel, text, seq));

  if FhasJsonl then
  begin
    root := newEventObject('segment_final', seq);
    try
      root.Add('source_kind', sourceKindOf(aItem));
      root.Add('text', text);
      root.Add('start_ms', aStartMs);
      root.Add('end_ms', aEndMs);
      root.Add('segment_id', aSegmentId);
      if aDaemonLabel <> '' then
        root.Add('daemon_endpoint', aDaemonLabel);
      writeJsonlLine(root.AsJSON);
    finally
      root.Free;
    end;
  end;
end;

procedure TRecorderProtocolWriter.writeServerFinal(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  const aResult: TRecorderResult;
  aFragmentIndex: Integer;
  aFragmentCount: Integer
);
var
  seq: Int64;
  inputPath: string;
  root: TJSONObject;
begin
  if (not FhasJsonl) and (not FhasPlain) then
    Exit;

  seq := nextSeq;

  if FhasPlain then
    writePlainLine(buildEventLine('server_final', aResult.TargetModel, aResult.Text, seq));

  if FhasJsonl then
  begin
    root := newEventObject('server_final', seq);
    try
      inputPath := aResult.InputPath;
      if inputPath = '' then
        inputPath := aItem.FilePath;
      if inputPath = '<<STDIN>>' then
        inputPath := '-';

      root.Add('backend', recorderBackendLabel(aSettings.Backend));
      root.Add('fragment_index', aFragmentIndex);
      root.Add('fragment_count', aFragmentCount);
      root.Add('ok', aResult.Ok);
      root.Add('status_code', aResult.StatusCode);
      root.Add('error_text', aResult.ErrorText);
      root.Add('job_id', aResult.JobId);
      root.Add('text', aResult.Text);
      root.Add('raw_text', aResult.RawText);
      root.Add('normalized_text', aResult.NormalizedText);
      root.Add('target_model', aResult.TargetModel);
      root.Add('language', aResult.Language);
      if aResult.DetectedLanguage <> '' then
        root.Add('detected_language', aResult.DetectedLanguage);
      if aResult.SpeakerCount > 0 then
        root.Add('speaker_count', aResult.SpeakerCount);
      addSpeakerSegments(root, aResult.SpeakerSegments);
      root.Add('command_status', aResult.CommandStatus);
      root.Add('input_path', inputPath);
      writeJsonlLine(root.AsJSON);
    finally
      root.Free;
    end;
  end;
end;

procedure TRecorderProtocolWriter.writeFinal(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  const aResult: TRecorderResult
);
var
  seq: Int64;
  inputPath: string;
  line: string;
  root: TJSONObject;
begin
  if (not FhasJsonl) and (not FhasPlain) then
    Exit;

  seq := nextSeq;

  if FhasPlain then
  begin
    line := Trim(aResult.Text);
    if line = '' then
      line := Trim(aResult.NormalizedText);
    if line = '' then
      line := Trim(aResult.RawText);
    writePlainLine(buildEventLine('final', aResult.TargetModel, line, seq));
  end;

  if FhasJsonl then
  begin
    root := newEventObject('final', seq);
    try
      inputPath := aResult.InputPath;
      if inputPath = '' then
        inputPath := aItem.FilePath;
      if inputPath = '<<STDIN>>' then
        inputPath := '-';

      root.Add('ok', aResult.Ok);
      root.Add('backend', aResult.BackendName);
      root.Add('mode', aResult.ModeName);
      root.Add('language', aResult.Language);
      if aResult.DetectedLanguage <> '' then
        root.Add('detected_language', aResult.DetectedLanguage);
      if aResult.SpeakerCount > 0 then
        root.Add('speaker_count', aResult.SpeakerCount);
      root.Add('text', aResult.Text);
      root.Add('raw_text', aResult.RawText);
      root.Add('normalized_text', aResult.NormalizedText);
      root.Add('target_model', aResult.TargetModel);
      root.Add('command_status', aResult.CommandStatus);
      root.Add('input_path', inputPath);
      root.Add('source_kind', sourceKindOf(aItem));
      root.Add('size_bytes', aItem.SizeBytes);
      root.Add('speaker_aware', aSettings.SpeakerEmbeddings);
      addSpeakerSegments(root, aResult.SpeakerSegments);
      writeJsonlLine(root.AsJSON);
    finally
      root.Free;
    end;
  end;
end;

procedure TRecorderProtocolWriter.writeError(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  const aStage: string;
  const aMessage: string;
  aStatusCode: Integer
);
var
  seq: Int64;
  inputPath: string;
  root: TJSONObject;
begin
  if (not FhasJsonl) and (not FhasPlain) then
    Exit;

  seq := nextSeq;

  if FhasPlain then
    writePlainLine(buildEventLine('error', aStage, aMessage, seq));

  if FhasJsonl then
  begin
    root := newEventObject('error', seq);
    try
      inputPath := aItem.FilePath;
      if inputPath = '' then
        inputPath := aItem.FileName;
      if inputPath = '<<STDIN>>' then
        inputPath := '-';

      root.Add('backend', recorderBackendLabel(aSettings.Backend));
      root.Add('mode', speechModeLabel(aSettings.Mode));
      root.Add('language', aSettings.Language);
      root.Add('stage', aStage);
      root.Add('message', aMessage);
      root.Add('status_code', aStatusCode);
      root.Add('input_path', inputPath);
      writeJsonlLine(root.AsJSON);
    finally
      root.Free;
    end;
  end;
end;

initialization
  Randomize;

end.