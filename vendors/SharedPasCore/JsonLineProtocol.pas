unit JsonLineProtocol;

{$mode objfpc}{$H+}

interface

uses
    SysUtils;

{*******************************************************************************
* readStdinLine
*   Reads one UTF-8 line from stdin. Returns True on success, False on EOF
*   or I/O error (pipe closed from the other end).
*******************************************************************************}
function readStdinLine(out aLine: string): Boolean;

{*******************************************************************************
* writeStdoutLine
*   Writes a JSON line to stdout and flushes immediately so the reader
*   does not block waiting for a buffer fill.
*******************************************************************************}
procedure writeStdoutLine(const aLine: string);

implementation

var
    gStdoutLock: TRTLCriticalSection;

{*******************************************************************************
* readStdinLine
*******************************************************************************}
function readStdinLine(out aLine: string): Boolean;
var
    ioErr: Integer;
begin
    aLine := '';
    {$I-}
    ReadLn(Input, aLine);
    ioErr := IOResult;
    {$I+}
    Result := ioErr = 0;
end;

{*******************************************************************************
* writeStdoutLine
*******************************************************************************}
procedure writeStdoutLine(const aLine: string);
begin
    EnterCriticalSection(gStdoutLock);
    try
        WriteLn(aLine);
        Flush(Output);
    finally
        LeaveCriticalSection(gStdoutLock);
    end;
end;

initialization
    InitCriticalSection(gStdoutLock);

finalization
    DoneCriticalSection(gStdoutLock);

end.
