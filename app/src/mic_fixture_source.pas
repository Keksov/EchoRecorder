unit mic_fixture_source;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  echo_recorder_core_api;

type
  TAudioFixture = echo_recorder_core_api.TRecorderInputItem;
  TAudioFixtures = echo_recorder_core_api.TRecorderInputItems;

function    formatAudioFixtureSize(aSizeBytes: Int64): string;
function    loadAudioFixtures(const aTestsDir: string): TAudioFixtures;
function    readAudioFixtureBytes(const aFixture: TAudioFixture): TBytes;

implementation

uses
  echo_recorder_core_sources;

function formatAudioFixtureSize(aSizeBytes: Int64): string;
begin
  Result := formatInputItemSize(aSizeBytes);
end;

function loadAudioFixtures(const aTestsDir: string): TAudioFixtures;
begin
  Result := echo_recorder_core_sources.loadAudioFixtures(aTestsDir);
end;

function readAudioFixtureBytes(const aFixture: TAudioFixture): TBytes;
begin
  Result := readInputItemBytes(aFixture);
end;

end.