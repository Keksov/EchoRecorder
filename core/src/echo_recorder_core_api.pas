unit echo_recorder_core_api;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TIntegerArray = array of Integer;

  TDaemonKind = (dkVosk, dkWhisper);
  TDaemonEndpoint = record
    Kind: TDaemonKind;
    Host: string;
    Port: Integer;
  end;
  TDaemonEndpoints = array of TDaemonEndpoint;

  TSpeechMode = (smCommand, smDictation);
  TRecorderBackend = (rbTransport, rbLocalDictation, rbVoskDaemon);

  TRecorderLogFormat = (lfJsonl, lfPlain);
  TRecorderLogTarget = record
    Format              : TRecorderLogFormat;
    Path                : string;
  end;
  TRecorderLogOutputs = array of TRecorderLogTarget;

  TRecorderInputItem = record
    DisplayName: string;
    FileName: string;
    FilePath: string;
    SizeBytes: Int64;
  end;

  TRecorderInputItems = array of TRecorderInputItem;

  TRecorderSpeakerSegment = record
    SegmentId: Integer;
    StartMs: Int64;
    EndMs: Int64;
    SpeakerId: string;
    Text: string;
  end;

  TRecorderSpeakerSegments = array of TRecorderSpeakerSegment;

  TRecorderResult = record
    Ok: Boolean;
    StatusCode: Integer;
    ErrorText: string;
    ResponseBody: string;
    JobId: string;
    BackendName: string;
    ModeName: string;
    Language: string;
    DetectedLanguage: string;
    TargetModel: string;
    CommandStatus: string;
    Text: string;
    RawText: string;
    NormalizedText: string;
    InputPath: string;
    SpeakerCount: Integer;
    SpeakerSegments: TRecorderSpeakerSegments;
  end;

  TRecorderSettings = record
    BaseUrl: string;
    DaemonHost: string;
    DaemonPort: Integer;
    DaemonPorts: TIntegerArray;
    DaemonEndpoints: TDaemonEndpoints;
    InputFormat: string;
    Language: string;
    Mode: TSpeechMode;
    SpeakerEmbeddings: Boolean;
    TestsDir: string;
    InputFilePath: string;
    LogOutputs: TRecorderLogOutputs;
    Backend: TRecorderBackend;
  end;

  TRecorderInputSource = class
  public
    function    next(out aItem: TRecorderInputItem): Boolean; virtual; abstract;
  end;

  TRecorderTransport = class
  public
    function    recognize(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem
    ): TRecorderResult; virtual; abstract;
    function    recognizeBytes(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem;
      const aAudioBytes: TBytes
    ): TRecorderResult; virtual; abstract;
  end;

  TLocalDictationEngine = class
  public
    function    recognize(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem
    ): TRecorderResult; virtual; abstract;
  end;

  TRecorderResultSink = class
  public
    procedure   writeResult(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem;
      const aResult: TRecorderResult
    ); virtual; abstract;
  end;

function    emptyRecorderInputItem: TRecorderInputItem;
function    emptyRecorderResult: TRecorderResult;
function    defaultRecorderSettings: TRecorderSettings;
function    defaultVoskDaemonPort(const aSettings: TRecorderSettings): Integer;
function    daemonKindLabel(aKind: TDaemonKind): string;
function    speechModeToApiValue(aMode: TSpeechMode): string;
function    speechModeLabel(aMode: TSpeechMode): string;
function    recorderBackendLabel(aBackend: TRecorderBackend): string;

implementation

function emptyRecorderInputItem: TRecorderInputItem;
begin
  Result.DisplayName := '';
  Result.FileName := '';
  Result.FilePath := '';
  Result.SizeBytes := 0;
end;

function emptyRecorderResult: TRecorderResult;
begin
  Result.Ok := False;
  Result.StatusCode := 0;
  Result.ErrorText := '';
  Result.ResponseBody := '';
  Result.JobId := '';
  Result.BackendName := '';
  Result.ModeName := '';
  Result.Language := '';
  Result.DetectedLanguage := '';
  Result.TargetModel := '';
  Result.CommandStatus := '';
  Result.Text := '';
  Result.RawText := '';
  Result.NormalizedText := '';
  Result.InputPath := '';
  Result.SpeakerCount := 0;
  SetLength(Result.SpeakerSegments, 0);
end;

function defaultRecorderSettings: TRecorderSettings;
begin
  Result.BaseUrl := 'http://127.0.0.1:3000';
  Result.DaemonHost := '127.0.0.1';
  Result.DaemonPort := 0;
  SetLength(Result.DaemonPorts, 0);
  SetLength(Result.DaemonEndpoints, 0);
  Result.InputFormat := '';
  Result.Language := 'ru';
  Result.Mode := smDictation;
  Result.SpeakerEmbeddings := False;
  Result.TestsDir := '';
  Result.InputFilePath := '';
  SetLength(Result.LogOutputs, 0);
  Result.Backend := rbTransport;
end;

function defaultVoskDaemonPort(const aSettings: TRecorderSettings): Integer;
begin
  if SameText(aSettings.Language, 'en') then
    Exit(7703);

  if aSettings.Mode = smCommand then
    Exit(7702);

  Result := 7701;
end;

function daemonKindLabel(aKind: TDaemonKind): string;
begin
  case aKind of
    dkVosk:
      Result := 'vosk';
    dkWhisper:
      Result := 'whisper';
  end;
end;

function speechModeToApiValue(aMode: TSpeechMode): string;
begin
  case aMode of
    smCommand:
      Result := 'command';
    smDictation:
      Result := 'dictation';
  end;
end;

function speechModeLabel(aMode: TSpeechMode): string;
begin
  Result := speechModeToApiValue(aMode);
end;

function recorderBackendLabel(aBackend: TRecorderBackend): string;
begin
  case aBackend of
    rbTransport:
      Result := 'transport';
    rbLocalDictation:
      Result := 'local-dictation';
    rbVoskDaemon:
      Result := 'daemon';
  end;
end;

end.