unit echo_recorder_core_runtime;

{$mode objfpc}{$H+}

interface

uses
  echo_recorder_core_api;

function    runRecorderCli(const aSettings: TRecorderSettings): Integer;

implementation

uses
  SysUtils,
  echo_recorder_core_audio,
  echo_recorder_core_paths,
  echo_recorder_core_protocol,
  echo_recorder_core_sources,
  echo_recorder_core_transport,
  echo_recorder_core_voskdaemon,
  echo_recorder_core_vosk;

type
  TUnavailableLocalDictationEngine = class(TLocalDictationEngine)
  public
    function    recognize(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem
    ): TRecorderResult; override;
  end;

function createTransport(const aSettings: TRecorderSettings): TRecorderTransport;
begin
  case aSettings.Backend of
    rbTransport:
      Result := THttpSpeechTransport.Create;
    rbLocalDictation,
    rbVoskDaemon:
      Result := nil;
  end;
end;

function createLocalDictationEngine(const aSettings: TRecorderSettings): TLocalDictationEngine;
begin
  case aSettings.Backend of
    rbTransport:
      Result := nil;
    rbLocalDictation:
      Result := TUnavailableLocalDictationEngine.Create;
    rbVoskDaemon:
      Result := nil;
  end;
end;

procedure hydrateResultDefaults(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  var aResult: TRecorderResult
);
begin
  if aResult.ModeName = '' then
    aResult.ModeName := speechModeLabel(aSettings.Mode);
  if aResult.Language = '' then
    aResult.Language := aSettings.Language;
  if aResult.BackendName = '' then
    aResult.BackendName := recorderBackendLabel(aSettings.Backend);
  if aResult.InputPath = '' then
    aResult.InputPath := aItem.FilePath;
end;

function TUnavailableLocalDictationEngine.recognize(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem
): TRecorderResult;
begin
  Result := emptyRecorderResult;
  Result.StatusCode := 501;
  Result.ModeName := speechModeLabel(aSettings.Mode);
  Result.Language := aSettings.Language;
  Result.InputPath := aItem.FilePath;
  Result.BackendName := recorderBackendLabel(rbLocalDictation);
  Result.ErrorText := 'Local dictation is not implemented in this slice';
end;

procedure appendTextWithSpace(var aTarget: string; const aValue: string);
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

procedure mergeFragmentResult(var aAggregate: TRecorderResult; const aFragment: TRecorderResult);
begin
  aAggregate.Ok := aAggregate.Ok and aFragment.Ok;
  if aAggregate.StatusCode = 0 then
    aAggregate.StatusCode := aFragment.StatusCode;
  if aFragment.ErrorText <> '' then
    aAggregate.ErrorText := aFragment.ErrorText;
  if aFragment.ResponseBody <> '' then
    aAggregate.ResponseBody := aFragment.ResponseBody;
  if aFragment.JobId <> '' then
    aAggregate.JobId := aFragment.JobId;
  if aFragment.TargetModel <> '' then
    aAggregate.TargetModel := aFragment.TargetModel;
  if aFragment.CommandStatus <> '' then
  begin
    if aAggregate.CommandStatus = '' then
      aAggregate.CommandStatus := aFragment.CommandStatus
    else if SameText(aFragment.CommandStatus, 'matched') then
      aAggregate.CommandStatus := aFragment.CommandStatus;
  end;

  appendTextWithSpace(aAggregate.Text, aFragment.Text);
  appendTextWithSpace(aAggregate.RawText, aFragment.RawText);
  appendTextWithSpace(aAggregate.NormalizedText, aFragment.NormalizedText);
end;

function buildPipeAggregateResult(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  const aLocalRun: TVoskLocalRun
): TRecorderResult;
begin
  Result := emptyRecorderResult;
  Result.Ok := True;
  Result.StatusCode := 200;
  Result.ModeName := speechModeLabel(aSettings.Mode);
  Result.Language := aSettings.Language;
  Result.BackendName := recorderBackendLabel(aSettings.Backend);
  Result.InputPath := aItem.FilePath;
  Result.RawText := aLocalRun.FinalText;
  Result.NormalizedText := aLocalRun.FinalText;
  Result.Text := aLocalRun.FinalText;
end;

function runTransportPipeFlow(
  const aSettings: TRecorderSettings;
  var aItem: TRecorderInputItem;
  aProtocol: TRecorderProtocolWriter;
  aTransport: TRecorderTransport;
  out aResult: TRecorderResult
): Integer;
var
  idx: Integer;
  encodedBytes: TBytes;
  localRun: TVoskLocalRun;
  submittedBytes: Int64;
  fragmentResult: TRecorderResult;
  audioData: TMonoPcmAudio;
  fragments: TAudioFragments;
begin
  Result := 1;
  aResult := emptyRecorderResult;

  encodedBytes := readInputItemBytes(aItem);
  aItem.SizeBytes := Length(encodedBytes);
  aProtocol.writeSource(aItem);

  audioData := decodeEncodedAudioBytes(encodedBytes, aSettings.InputFormat);
  localRun := runLocalRecognition(aSettings, audioData, aItem, aProtocol);
  fragments := createFragmentsFromSampleEnds(audioData, localRun.FragmentEndSamples);
  aResult := buildPipeAggregateResult(aSettings, aItem, localRun);

  if Length(fragments) = 0 then
    raise Exception.Create('No backend fragments were produced from stdin audio');

  submittedBytes := 0;
  for idx := 0 to High(fragments) do
  begin
    aProtocol.writeBackendStarted(aSettings, idx + 1, Length(fragments));
    fragmentResult := aTransport.recognizeBytes(aSettings, aItem, fragments[idx].WavBytes);
    hydrateResultDefaults(aSettings, aItem, fragmentResult);
    if not fragmentResult.Ok then
    begin
      aProtocol.writeError(aSettings, aItem, 'backend', fragmentResult.ErrorText, fragmentResult.StatusCode);
      aResult := fragmentResult;
      Exit(1);
    end;

    Inc(submittedBytes, Length(fragments[idx].WavBytes));
    mergeFragmentResult(aResult, fragmentResult);
    aProtocol.writeServerFinal(aSettings, aItem, fragmentResult, idx + 1, Length(fragments));
    aProtocol.writeBackendProgress(aSettings, idx + 1, Length(fragments), idx + 1, submittedBytes);
  end;

  hydrateResultDefaults(aSettings, aItem, aResult);
  if aResult.Text = '' then
    aResult.Text := localRun.FinalText;
  if aResult.RawText = '' then
    aResult.RawText := localRun.FinalText;
  if aResult.NormalizedText = '' then
    aResult.NormalizedText := localRun.FinalText;

  aProtocol.writeFinal(aSettings, aItem, aResult);
  Result := 0;
end;

function runRecorderCli(const aSettings: TRecorderSettings): Integer;
var
  item: TRecorderInputItem;
  protocol: TRecorderProtocolWriter;
  source: TRecorderInputSource;
  resultData: TRecorderResult;
  settings: TRecorderSettings;
  localEngine: TLocalDictationEngine;
  transport: TRecorderTransport;
begin
  item := emptyRecorderInputItem;
  protocol := nil;
  source := nil;
  settings := aSettings;
  localEngine := nil;
  transport := nil;
  resultData := emptyRecorderResult;

  if Trim(settings.TestsDir) = '' then
    settings.TestsDir := getTestsDir;

  try
    try
      protocol := TRecorderProtocolWriter.Create(settings.LogOutputs);
      source := TFileInputSource.Create(settings);

      protocol.writeAccepted(settings);

      if not source.next(item) then
        raise Exception.Create('No prerecorded input source item resolved');

      if (settings.Backend = rbTransport) and (item.FilePath = '<<STDIN>>') then
      begin
        transport := createTransport(settings);
        Result := runTransportPipeFlow(settings, item, protocol, transport, resultData);
        Exit;
      end;

      protocol.writeSource(item);

      case settings.Backend of
        rbTransport:
        begin
          transport := createTransport(settings);
          protocol.writeBackendStarted(settings, 1, 1);
          resultData := transport.recognize(settings, item);
          if item.SizeBytes > 0 then
            protocol.writeBackendProgress(settings, 1, 1, 1, item.SizeBytes);
        end;
        rbLocalDictation:
        begin
          if SameText(settings.InputFormat, 'pcm16le') and (item.FilePath = '<<STDIN>>') then
            resultData := runLocalPcmStreamRecognition(settings, item, protocol)
          else
          begin
            localEngine := createLocalDictationEngine(settings);
            resultData := localEngine.recognize(settings, item);
          end;
        end;
        rbVoskDaemon:
        begin
          resultData := runDaemonPcmStreamRecognition(settings, item, protocol);
        end;
      end;

      hydrateResultDefaults(settings, item, resultData);
      if resultData.Ok then
      begin
        if settings.Backend = rbTransport then
          protocol.writeServerFinal(settings, item, resultData, 1, 1);
        protocol.writeFinal(settings, item, resultData);
        Result := 0
      end
      else
      begin
        protocol.writeError(settings, item, 'recognize', resultData.ErrorText, resultData.StatusCode);
        Result := 1;
      end;
    except
      on E: Exception do
      begin
        if protocol = nil then
          protocol := TRecorderProtocolWriter.Create(settings.LogOutputs);

        resultData := emptyRecorderResult;
        resultData.ModeName := speechModeLabel(settings.Mode);
        resultData.Language := settings.Language;
        resultData.InputPath := item.FilePath;
        resultData.BackendName := recorderBackendLabel(settings.Backend);
        resultData.ErrorText := E.Message;
        if (resultData.InputPath = '') and (Trim(settings.InputFilePath) <> '') then
          resultData.InputPath := ExpandFileName(settings.InputFilePath);

        try
          protocol.writeError(settings, item, 'runtime', resultData.ErrorText, resultData.StatusCode);
        except
          WriteLn(StdErr, E.Message);
        end;

        Result := 1;
      end;
    end;
  finally
    transport.Free;
    localEngine.Free;
    source.Free;
    protocol.Free;
  end;
end;

end.