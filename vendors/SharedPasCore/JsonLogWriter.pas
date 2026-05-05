unit JsonLogWriter;

{$mode objfpc}{$H+}

interface

uses
    SysUtils,
    JsonLineProtocol;

const
    RING_SIZE               = 256;

type
    TLogOutputFormat = (LOG_FORMAT_PLAIN,
        LOG_FORMAT_JSONL);

    {***************************************************************************
     * TStringRingBuffer
     *   Lock-free single-producer / single-consumer ring buffer of strings.
     *   push() from any ONE producer thread, tryPop() from a SINGLE consumer.
     ***************************************************************************}
    TStringRingBuffer = class
private
    Fitems                  : array[0..RING_SIZE - 1] of string;
    Fhead                   : Integer;
    Ftail                   : Integer;

public
    constructor Create;
    destructor  Destroy; override;

    procedure   push(const aLine: string);
    function    tryPop(out aLine: string): Boolean;
    end;

    {***************************************************************************
     * TJsonLogWriter
     *   Writes plain or structured log lines to a file or stdout.
     *   Supports plain and JSONL output formats.
     ***************************************************************************}
    TJsonLogWriter = class
private
    FlogFile                : TextFile;
    FlogFormat              : TLogOutputFormat;
    FuseStdout              : Boolean;
    FfileOpened             : Boolean;

public
    constructor Create(const aFileName: string;
        aLogFormat: TLogOutputFormat = LOG_FORMAT_PLAIN);
    destructor  Destroy; override;

    procedure   writeLine(const aLine: string);
    function    writePlainLine(const aLine: string): Boolean;
    function    writesStructured(): Boolean;
    procedure   finish;

    property UsesStdout: Boolean read FuseStdout;
    property LogFormat: TLogOutputFormat read FlogFormat;
    end;

function    jsonLogTimestamp(const aApp: string): string;
function    jsonLogFloat3(aValue: Double): string;

implementation

var
    gDotFmt: TFormatSettings;

{ TStringRingBuffer }

constructor TStringRingBuffer.Create;
var
    i: Integer;
begin
    inherited Create;
    Fhead := 0;
    Ftail := 0;
    for i := 0 to RING_SIZE - 1 do
        Fitems[i] := '';
end;

destructor TStringRingBuffer.Destroy;
var
    i: Integer;
begin
    for i := 0 to RING_SIZE - 1 do
        Fitems[i] := '';
    inherited Destroy;
end;

procedure TStringRingBuffer.push(const aLine: string);
var
    next: Integer;
begin
    next := (Fhead + 1) mod RING_SIZE;
    if next = Ftail then
        Exit;  // ring full — drop
    Fitems[Fhead] := aLine;
    Fhead := next;
end;

function TStringRingBuffer.tryPop(out aLine: string): Boolean;
begin
    if Ftail = Fhead then
    begin
        aLine := '';
        Result := False;
        Exit;
    end;
    aLine := Fitems[Ftail];
    Fitems[Ftail] := '';
    Ftail := (Ftail + 1) mod RING_SIZE;
    Result := True;
end;

{ TJsonLogWriter }

constructor TJsonLogWriter.Create(const aFileName: string;
    aLogFormat: TLogOutputFormat);
begin
    inherited Create;
    FlogFormat := aLogFormat;

    if aFileName = '-' then
    begin
        FuseStdout := True;
        FfileOpened := False;
    end
    else
    begin
        FuseStdout := False;
        AssignFile(FlogFile, aFileName);
        Rewrite(FlogFile);
        FfileOpened := True;
    end;
end;

destructor TJsonLogWriter.Destroy;
begin
    if FfileOpened then
        CloseFile(FlogFile);
    inherited Destroy;
end;

procedure TJsonLogWriter.writeLine(const aLine: string);
var
    out_: string;
begin
    if FlogFormat = LOG_FORMAT_PLAIN then
        Exit;

    out_ := aLine;

    if FuseStdout then
        writeStdoutLine(out_)
    else
    begin
        WriteLn(FlogFile, out_);
        System.Flush(FlogFile);
    end;
end;

function TJsonLogWriter.writePlainLine(const aLine: string): Boolean;
begin
    Result := False;
    if FlogFormat <> LOG_FORMAT_PLAIN then
        Exit;

    if FuseStdout then
        writeStdoutLine(aLine)
    else
    begin
        WriteLn(FlogFile, aLine);
        System.Flush(FlogFile);
    end;
    Result := True;
end;

function TJsonLogWriter.writesStructured(): Boolean;
begin
    Result := FlogFormat = LOG_FORMAT_JSONL;
end;

procedure TJsonLogWriter.finish;
begin
    if not FuseStdout then
        System.Flush(FlogFile);
end;

{ Standalone helpers }

function jsonLogFloat3(aValue: Double): string;
begin
    Result := FormatFloat('0.000', aValue, gDotFmt);
end;

function jsonLogTimestamp(const aApp: string): string;
var
    n: TDateTime;
    epoch: Double;
    ticks: QWord;
begin
    n := Now;
    ticks := GetTickCount64;
    epoch := (n - 25569) * 86400.0;
    Result := '"ap":"' + aApp + '"' +
              ',"t":"' + FormatDateTime('yyyy.mm.dd hh:nn:ss.zzz', n) + '"' +
              ',"tk":' + IntToStr(Int64(ticks)) +
              ',"ep":' + jsonLogFloat3(epoch);
end;

initialization
    gDotFmt := DefaultFormatSettings;
    gDotFmt.DecimalSeparator := '.';
    gDotFmt.ThousandSeparator := #0;

end.
