unit main_form;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  Forms,
  Controls,
  Graphics,
  ExtCtrls,
  StdCtrls,
  Pixie.HtmlView,
  echo_recorder_core_api,
  mic_fixture_source,
  speech_client;

type
  TMainForm = class(TForm)
    procedure FormCreate({%H-}Sender: TObject);
  private
    FhtmlView: TPixieHtmlView;
    FtopPanel: TPanel;
    FbaseUrlEdit: TEdit;
    FfixtureBox: TComboBox;
    FmodeBox: TComboBox;
    FsimulateButton: TButton;
    Ffixtures: TAudioFixtures;
    procedure buildUi;
    function getSelectedFixture(out aFixture: TAudioFixture): Boolean;
    procedure loadFixtures;
    procedure renderBackendView(const aResponse: TSpeechResponse; aHasResponse: Boolean);
    procedure simulateFixture({%H-}Sender: TObject);
  end;

var
  MainForm: TMainForm;

implementation

uses
  app_paths;

{$R *.lfm}

function htmlEscape(const aValue: string): string;
begin
  Result := StringReplace(aValue, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

function speechModeFromIndex(aIndex: Integer): TSpeechMode;
begin
  if aIndex = 1 then
    Result := echo_recorder_core_api.smCommand
  else
    Result := echo_recorder_core_api.smDictation;
end;

function speechModeLabel(aMode: TSpeechMode): string;
begin
  case aMode of
    echo_recorder_core_api.smCommand:
      Result := 'command';
    echo_recorder_core_api.smDictation:
      Result := 'dictation';
  end;
end;

procedure TMainForm.buildUi;
var
  labelBox: TLabel;
begin
  FtopPanel := TPanel.Create(Self);
  FtopPanel.Parent := Self;
  FtopPanel.Align := alTop;
  FtopPanel.Height := 124;
  FtopPanel.BevelOuter := bvNone;
  FtopPanel.Color := $00E6DED0;

  labelBox := TLabel.Create(FtopPanel);
  labelBox.Parent := FtopPanel;
  labelBox.Left := 20;
  labelBox.Top := 18;
  labelBox.Caption := 'Simulated microphone fixture';

  FfixtureBox := TComboBox.Create(FtopPanel);
  FfixtureBox.Parent := FtopPanel;
  FfixtureBox.Left := 20;
  FfixtureBox.Top := 40;
  FfixtureBox.Width := 280;
  FfixtureBox.Style := csDropDownList;

  labelBox := TLabel.Create(FtopPanel);
  labelBox.Parent := FtopPanel;
  labelBox.Left := 320;
  labelBox.Top := 18;
  labelBox.Caption := 'Speech mode';

  FmodeBox := TComboBox.Create(FtopPanel);
  FmodeBox.Parent := FtopPanel;
  FmodeBox.Left := 320;
  FmodeBox.Top := 40;
  FmodeBox.Width := 130;
  FmodeBox.Style := csDropDownList;
  FmodeBox.Items.Add('dictation');
  FmodeBox.Items.Add('command');
  FmodeBox.ItemIndex := 0;

  labelBox := TLabel.Create(FtopPanel);
  labelBox.Parent := FtopPanel;
  labelBox.Left := 470;
  labelBox.Top := 18;
  labelBox.Caption := 'EchoScript base URL';

  FbaseUrlEdit := TEdit.Create(FtopPanel);
  FbaseUrlEdit.Parent := FtopPanel;
  FbaseUrlEdit.Left := 470;
  FbaseUrlEdit.Top := 40;
  FbaseUrlEdit.Width := 220;
  FbaseUrlEdit.Text := 'http://127.0.0.1:3000';

  FsimulateButton := TButton.Create(FtopPanel);
  FsimulateButton.Parent := FtopPanel;
  FsimulateButton.Left := 710;
  FsimulateButton.Top := 38;
  FsimulateButton.Width := 154;
  FsimulateButton.Height := 30;
  FsimulateButton.Caption := 'Simulate recording';
  FsimulateButton.OnClick := @simulateFixture;

  labelBox := TLabel.Create(FtopPanel);
  labelBox.Parent := FtopPanel;
  labelBox.Left := 20;
  labelBox.Top := 82;
  labelBox.Caption :=
    'The selected .ogg file is posted as application/octet-stream to /api/v2/speech/recognize.';

  FhtmlView := TPixieHtmlView.Create(Self);
  FhtmlView.Parent := Self;
  FhtmlView.Align := alClient;
  FhtmlView.Color := $00F4F0E8;
end;

function TMainForm.getSelectedFixture(out aFixture: TAudioFixture): Boolean;
var
  idx: Integer;
begin
  Result := False;
  idx := FfixtureBox.ItemIndex;
  if (idx < 0) or (idx > High(Ffixtures)) then
    Exit;

  aFixture := Ffixtures[idx];
  Result := True;
end;

procedure TMainForm.loadFixtures;
var
  idx: Integer;
  item: TAudioFixture;
begin
  Ffixtures := loadAudioFixtures(GetTestsDir);

  FfixtureBox.Items.BeginUpdate;
  try
    FfixtureBox.Items.Clear;
    for idx := 0 to High(Ffixtures) do
    begin
      item := Ffixtures[idx];
      FfixtureBox.Items.Add(
        Format('%s (%s)', [item.DisplayName, formatAudioFixtureSize(item.SizeBytes)])
      );
    end;
  finally
    FfixtureBox.Items.EndUpdate;
  end;

  FfixtureBox.Enabled := Length(Ffixtures) > 0;
  FsimulateButton.Enabled := Length(Ffixtures) > 0;
  if Length(Ffixtures) > 0 then
    FfixtureBox.ItemIndex := 0;
end;

procedure TMainForm.renderBackendView(const aResponse: TSpeechResponse; aHasResponse: Boolean);
var
  idx: Integer;
  html: TStringList;
  item: TAudioFixture;
  mode: TSpeechMode;
begin
  mode := speechModeFromIndex(FmodeBox.ItemIndex);
  html := TStringList.Create;
  try
    html.Add('<!doctype html>');
    html.Add('<html><head><style>');
    html.Add('body{margin:0;padding:28px;background:#f4f0e8;color:#1c1917;font-family:"Segoe UI";}');
    html.Add('h1{margin:0 0 10px 0;font-size:32px;line-height:1.1;}');
    html.Add('h2{margin:0 0 12px 0;font-size:18px;line-height:1.2;}');
    html.Add('p{margin:0 0 12px 0;font-size:15px;line-height:1.55;}');
    html.Add('.hero{max-width:920px;margin:0 auto 18px auto;padding:24px;border:1px solid #d6cfc0;border-radius:24px;background:#fffdf8;}');
    html.Add('.grid{max-width:920px;margin:0 auto;display:grid;grid-template-columns:1fr 1fr;gap:18px;}');
    html.Add('.card{padding:20px;border:1px solid #d6cfc0;border-radius:20px;background:#fffdf8;}');
    html.Add('.wide{grid-column:1 / span 2;}');
    html.Add('ul{margin:0;padding-left:18px;}');
    html.Add('li{margin:0 0 10px 0;font-size:15px;line-height:1.45;}');
    html.Add('code{display:inline-block;padding:4px 8px;border-radius:10px;background:#eee5d6;font-size:13px;}');
    html.Add('.ok{color:#166534;}');
    html.Add('.warn{color:#9a3412;}');
    html.Add('.pill{display:inline-block;padding:4px 10px;border-radius:999px;background:#eee5d6;font-size:13px;margin-right:8px;}');
    html.Add('.text{padding:14px;border-radius:16px;background:#f8f4ec;border:1px solid #e5dccd;white-space:pre-wrap;}');
    html.Add('</style></head><body>');
    html.Add('<section class="hero">');
    html.Add('<h1>Backend design: simulated microphone</h1>');
    html.Add('<p>EchoRecorder now treats prerecorded <code>.ogg</code> files in <code>' +
      htmlEscape(GetRepoRelativePath(GetTestsDir)) +
      '</code> as a deterministic microphone source for backend work.</p>');
    html.Add('<p><span class="pill">mode=' + htmlEscape(speechModeLabel(mode)) + '</span>' +
      '<span class="pill">endpoint=' + htmlEscape(Trim(FbaseUrlEdit.Text)) + '</span>' +
      '<span class="pill">fixtures=' + IntToStr(Length(Ffixtures)) + '</span></p>');
    html.Add('</section>');
    html.Add('<section class="grid">');
    html.Add('<article class="card">');
    html.Add('<h2>Fixture source</h2>');
    if Length(Ffixtures) = 0 then
    begin
      html.Add('<p class="warn">No .ogg fixtures were found in the tests directory.</p>');
    end
    else
    begin
      html.Add('<ul>');
      for idx := 0 to High(Ffixtures) do
      begin
        item := Ffixtures[idx];
        if idx = FfixtureBox.ItemIndex then
          html.Add('<li><strong>' + htmlEscape(item.DisplayName) + '</strong> from <code>' +
            htmlEscape(GetRepoRelativePath(item.FilePath)) + '</code> (' +
            htmlEscape(formatAudioFixtureSize(item.SizeBytes)) + ')</li>')
        else
          html.Add('<li>' + htmlEscape(item.DisplayName) + ' from <code>' +
            htmlEscape(GetRepoRelativePath(item.FilePath)) + '</code> (' +
            htmlEscape(formatAudioFixtureSize(item.SizeBytes)) + ')</li>');
      end;
      html.Add('</ul>');
    end;
    html.Add('</article>');
    html.Add('<article class="card">');
    html.Add('<h2>Backend contract</h2>');
    html.Add('<p>The client posts raw audio bytes to <code>/api/v2/speech/recognize?mode=' +
      htmlEscape(speechModeLabel(mode)) +
      '&amp;language=ru</code> with <code>application/octet-stream</code>.</p>');
    html.Add('<p>This bypasses the real microphone for now, but preserves the exact transport used by EchoScript buffered speech.</p>');
    html.Add('</article>');
    html.Add('<article class="card wide">');
    if aHasResponse then
    begin
      if aResponse.Ok then
      begin
        html.Add('<h2>Last recognition</h2>');
        html.Add('<p class="ok">HTTP ' + IntToStr(aResponse.StatusCode) +
          ' · target model <code>' + htmlEscape(aResponse.TargetModel) + '</code></p>');
        html.Add('<p><span class="pill">job=' + htmlEscape(aResponse.JobId) + '</span>' +
          '<span class="pill">language=' + htmlEscape(aResponse.Language) + '</span>' +
          '<span class="pill">command_status=' + htmlEscape(aResponse.CommandStatus) + '</span></p>');
        html.Add('<p>Final text</p>');
        html.Add('<div class="text">' + htmlEscape(aResponse.Text) + '</div>');
        if aResponse.NormalizedText <> '' then
        begin
          html.Add('<p>Normalized text</p>');
          html.Add('<div class="text">' + htmlEscape(aResponse.NormalizedText) + '</div>');
        end;
        if (aResponse.RawText <> '') and (aResponse.RawText <> aResponse.NormalizedText) then
        begin
          html.Add('<p>Raw text</p>');
          html.Add('<div class="text">' + htmlEscape(aResponse.RawText) + '</div>');
        end;
      end
      else
      begin
        html.Add('<h2>Recognition failed</h2>');
        html.Add('<p class="warn">' + htmlEscape(aResponse.ErrorText) + '</p>');
        if aResponse.ResponseBody <> '' then
        begin
          html.Add('<p>Response body</p>');
          html.Add('<div class="text">' + htmlEscape(aResponse.ResponseBody) + '</div>');
        end;
      end;
    end
    else
    begin
      html.Add('<h2>Ready</h2>');
      html.Add('<p>Select a fixture, keep the default base URL or point it at another EchoScript instance, then click <code>Simulate recording</code>.</p>');
      html.Add('<p>The first backend slice is intentionally narrow: fixture-backed capture in the desktop app and a direct call to the existing buffered speech API.</p>');
    end;
    html.Add('</article>');
    html.Add('</section></body></html>');
    FhtmlView.LoadFromString(html.Text);
  finally
    html.Free;
  end;
end;

procedure TMainForm.simulateFixture({%H-}Sender: TObject);
var
  item: TAudioFixture;
  mode: TSpeechMode;
  data: TSpeechResponse;
begin
  if Sender = nil then
  begin
  end;

  if not getSelectedFixture(item) then
  begin
    renderBackendView(emptySpeechResponse, False);
    Exit;
  end;

  mode := speechModeFromIndex(FmodeBox.ItemIndex);
  Screen.Cursor := crHourGlass;
  FsimulateButton.Enabled := False;
  try
    data := recognizeAudioFixture(FbaseUrlEdit.Text, item, mode);
    renderBackendView(data, True);
  finally
    FsimulateButton.Enabled := Length(Ffixtures) > 0;
    Screen.Cursor := crDefault;
  end;
end;

procedure TMainForm.FormCreate({%H-}Sender: TObject);
begin
  if Sender = nil then
  begin
  end;

  Caption := 'EchoRecorder';
  buildUi;
  loadFixtures;
  renderBackendView(emptySpeechResponse, False);
end;

end.
