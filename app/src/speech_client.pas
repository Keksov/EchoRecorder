unit speech_client;

{$mode objfpc}{$H+}

interface

uses
  mic_fixture_source,
  echo_recorder_core_api;

type
  TSpeechMode = echo_recorder_core_api.TSpeechMode;
  TSpeechResponse = echo_recorder_core_api.TRecorderResult;

function    emptySpeechResponse: TSpeechResponse;
function    speechModeToApiValue(aMode: TSpeechMode): string;
function    recognizeAudioFixture(
  const aBaseUrl: string;
  const aFixture: TAudioFixture;
  aMode: TSpeechMode
): TSpeechResponse;

implementation

uses
  SysUtils,
  echo_recorder_core_transport;

function emptySpeechResponse: TSpeechResponse;
begin
  Result := emptyRecorderResult;
end;

function speechModeToApiValue(aMode: TSpeechMode): string;
begin
  Result := echo_recorder_core_api.speechModeToApiValue(aMode);
end;

function recognizeAudioFixture(
  const aBaseUrl: string;
  const aFixture: TAudioFixture;
  aMode: TSpeechMode
): TSpeechResponse;
var
  settings: TRecorderSettings;
  transport: THttpSpeechTransport;
begin
  settings := defaultRecorderSettings;
  settings.BaseUrl := Trim(aBaseUrl);
  settings.Mode := aMode;

  transport := THttpSpeechTransport.Create;
  try
    Result := transport.recognize(settings, aFixture);
  finally
    transport.Free;
  end;
end;

end.