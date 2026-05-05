unit LogCore;

{$mode objfpc}{$H+}

interface

uses
    SysUtils,
    JsonLogWriter;

type
    {***************************************************************************
     * TLogCore
     *   Unified logger: ring buffer + plain/structured writer + --log argument parsing.
     *   pushLine() from any single producer thread, flush() from main thread.
     ***************************************************************************}
    TLogCore = class
private
    Fring                   : TStringRingBuffer;
    Fwriter                 : TJsonLogWriter;
    Flock                   : TRTLCriticalSection;

private
    class function  isStructured(aLogger: TLogCore): Boolean;
    class function  tryWritePlainSink(aLogger: TLogCore;
        const aLine: string): Boolean;

public
    constructor Create(const aFileName: string;
        aLogFormat: TLogOutputFormat = LOG_FORMAT_PLAIN);
    destructor  Destroy; override;

    function    writesStructuredToStdout(): Boolean;
    procedure   pushLine(const aLine: string);
    procedure   flush;
    procedure   finish;

    class procedure writeConsoleLine(aLogger: TLogCore; const aLine: string);
    class procedure writeErrorLine(aLogger: TLogCore; const aLine: string); overload;
    class procedure writeErrorLine(aLogger: TLogCore;
        const aSource: string;
        const aLine: string); overload;
    class procedure writeRuntimeLine(aLogger: TLogCore;
        const aSource: string;
        const aLevel: string;
        const aLine: string);
    class function parseLogArg(out aTarget: string): Boolean;
    class function tryParseLogFormat(const aValue: string;
        out aLogFormat: TLogOutputFormat): Boolean;
    class function parseLogFormatArg(out aLogFormat: TLogOutputFormat): Boolean;
    end;

function jsonEscape(const aValue: string): string;

implementation

{ TLogCore }

function jsonEscape(const aValue: string): string;
var
    i: Integer;
    c: Char;
begin
    Result := '';
    SetLength(Result, 0);
    for i := 1 to Length(aValue) do
    begin
        c := aValue[i];
        case c of
            '"': Result := Result + '\"';
            '\': Result := Result + '\\';
            '/': Result := Result + '\/';
            #8: Result := Result + '\b';
            #9: Result := Result + '\t';
            #10: Result := Result + '\n';
            #12: Result := Result + '\f';
            #13: Result := Result + '\r';
        else
            if Ord(c) < 32 then
                Result := Result + '\u00' + IntToHex(Ord(c), 2)
            else
                Result := Result + c;
        end;
    end;
end;

function makeDiagEventJson(const aEvent: string;
    const aSource: string;
    const aLevel: string;
    const aLine: string): string;
begin
    Result := '{' + jsonLogTimestamp('br') +
        ',"event":"' + jsonEscape(aEvent) + '"' +
        ',"source":"' + jsonEscape(aSource) + '"' +
        ',"level":"' + jsonEscape(aLevel) + '"' +
        ',"message":"' + jsonEscape(aLine) + '"}';
end;

function makeDiagEventName(const aSource: string): string;
begin
    if SameText(aSource, 'ble') then
        Result := 'ble_diag'
    else
        Result := 'runtime_diag';
end;

{*******************************************************************************
* Create
*******************************************************************************}
constructor TLogCore.Create(const aFileName: string;
    aLogFormat: TLogOutputFormat);
begin
    inherited Create;
    Fring := TStringRingBuffer.Create;
    Fwriter := TJsonLogWriter.Create(aFileName, aLogFormat);
    InitCriticalSection(Flock);
end;

{*******************************************************************************
* writesStructuredToStdout
*******************************************************************************}
function TLogCore.writesStructuredToStdout(): Boolean;
begin
    Result := (Fwriter <> nil) and Fwriter.UsesStdout and Fwriter.writesStructured();
end;

{*******************************************************************************
* Destroy
*******************************************************************************}
destructor TLogCore.Destroy;
begin
    DoneCriticalSection(Flock);
    FreeAndNil(Fwriter);
    FreeAndNil(Fring);
    inherited Destroy;
end;

{*******************************************************************************
* pushLine
*******************************************************************************}
procedure TLogCore.pushLine(const aLine: string);
begin
    if (Fwriter <> nil) and (not Fwriter.writesStructured()) then
        Exit;

    EnterCriticalSection(Flock);
    try
        Fring.push(aLine);
    finally
        LeaveCriticalSection(Flock);
    end;
end;

{*******************************************************************************
* flush
*******************************************************************************}
procedure TLogCore.flush;
var
    line: string;
begin
    EnterCriticalSection(Flock);
    try
        while Fring.tryPop(line) do
            Fwriter.writeLine(line);
    finally
        LeaveCriticalSection(Flock);
    end;
end;

{*******************************************************************************
* finish
*******************************************************************************}
procedure TLogCore.finish;
var
    line: string;
begin
    EnterCriticalSection(Flock);
    try
        while Fring.tryPop(line) do
            Fwriter.writeLine(line);
        Fwriter.finish;
    finally
        LeaveCriticalSection(Flock);
    end;
end;

{*******************************************************************************
* isStructured
*******************************************************************************}
class function TLogCore.isStructured(aLogger: TLogCore): Boolean;
begin
    Result := (aLogger <> nil) and (aLogger.Fwriter <> nil) and
        aLogger.Fwriter.writesStructured();
end;

{*******************************************************************************
* tryWritePlainSink
*   Writes aLine to the plain sink. Returns True when the sink is stdout
*   (so the caller must not write to the console again).
*******************************************************************************}
class function TLogCore.tryWritePlainSink(aLogger: TLogCore;
    const aLine: string): Boolean;
var
    wrote: Boolean;
begin
    Result := False;
    if (aLogger = nil) or (aLogger.Fwriter = nil) then
        Exit;
    wrote := aLogger.Fwriter.writePlainLine(aLine);
    Result := wrote and aLogger.Fwriter.UsesStdout;
end;

{*******************************************************************************
* writeConsoleLine
*******************************************************************************}
class procedure TLogCore.writeConsoleLine(aLogger: TLogCore; const aLine: string);
begin
    if aLogger = nil then
    begin
        WriteLn(aLine);
        Exit;
    end;

    if aLogger.writesStructuredToStdout() then
        Exit;

    if tryWritePlainSink(aLogger, aLine) then
        Exit;

    WriteLn(aLine);
end;

{*******************************************************************************
* writeErrorLine
*******************************************************************************}
class procedure TLogCore.writeErrorLine(aLogger: TLogCore; const aLine: string);
begin
    writeErrorLine(aLogger, 'runtime', aLine);
end;

{*******************************************************************************
* writeErrorLine
*******************************************************************************}
class procedure TLogCore.writeErrorLine(aLogger: TLogCore;
    const aSource: string;
    const aLine: string);
begin
    if isStructured(aLogger) then
    begin
        aLogger.pushLine(makeDiagEventJson(makeDiagEventName(aSource),
            aSource, 'error', aLine));
        Exit;
    end;

    if tryWritePlainSink(aLogger, aLine) then
        Exit;

    WriteLn(ErrOutput, aLine);
end;

{*******************************************************************************
* writeRuntimeLine
*******************************************************************************}
class procedure TLogCore.writeRuntimeLine(aLogger: TLogCore;
    const aSource: string;
    const aLevel: string;
    const aLine: string);
begin
    if isStructured(aLogger) then
        aLogger.pushLine(makeDiagEventJson(makeDiagEventName(aSource),
            aSource, aLevel, aLine));
end;

{*******************************************************************************
* parseLogArg
*   Scans ParamStr for --log <target>.
*   Returns True if --log is found (aTarget set to file path or '-').
*   Raises exception if --log has no argument.
*******************************************************************************}
class function TLogCore.parseLogArg(out aTarget: string): Boolean;
var
    i: Integer;
begin
    Result := False;
    aTarget := '';
    i := 1;
    while i <= ParamCount do
    begin
        if ParamStr(i) = '--log' then
        begin
            if i + 1 > ParamCount then
                raise Exception.Create('--log requires an argument (filename or -)');
            aTarget := ParamStr(i + 1);
            Result := True;
            Exit;
        end;
        Inc(i);
    end;
end;

{*******************************************************************************
* tryParseLogFormat
*   Parses a log format token into TLogOutputFormat.
*   Supported: plain, jsonl.
*******************************************************************************}
class function TLogCore.tryParseLogFormat(const aValue: string;
    out aLogFormat: TLogOutputFormat): Boolean;
var
    valueText: string;
begin
    Result := True;
    valueText := LowerCase(Trim(aValue));

    if valueText = 'plain' then
        aLogFormat := LOG_FORMAT_PLAIN
    else if valueText = 'jsonl' then
        aLogFormat := LOG_FORMAT_JSONL
    else
        Result := False;
end;

{*******************************************************************************
* parseLogFormatArg
*   Scans ParamStr for --log-format=<plain|jsonl> or --log-format <plain|jsonl>.
*   Returns True if option is present.
*   Raises exception for missing or invalid value.
*******************************************************************************}
class function TLogCore.parseLogFormatArg(out aLogFormat: TLogOutputFormat): Boolean;
var
    i: Integer;
    arg: string;
    eqPos: Integer;
    valueText: string;
begin
    Result := False;
    aLogFormat := LOG_FORMAT_PLAIN;

    i := 1;
    while i <= ParamCount do
    begin
        arg := LowerCase(ParamStr(i));

        if arg = '--log-format' then
        begin
            if i + 1 > ParamCount then
                raise Exception.Create('--log-format requires one of: plain, jsonl');
            valueText := ParamStr(i + 1);
            if not tryParseLogFormat(valueText, aLogFormat) then
                raise Exception.Create('Invalid --log-format value: ' + valueText + ' (expected plain or jsonl)');
            Result := True;
            Exit;
        end;

        if Pos('--log-format=', arg) = 1 then
        begin
            eqPos := Pos('=', ParamStr(i));
            valueText := Trim(Copy(ParamStr(i), eqPos + 1, MaxInt));
            if valueText = '' then
                raise Exception.Create('--log-format requires one of: plain, jsonl');
            if not tryParseLogFormat(valueText, aLogFormat) then
                raise Exception.Create('Invalid --log-format value: ' + valueText + ' (expected plain or jsonl)');
            Result := True;
            Exit;
        end;

        Inc(i);
    end;
end;

end.
