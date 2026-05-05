unit app_paths;

{$mode objfpc}{$H+}

interface

function GetExecutableDir: string;
function GetRepoRootDir: string;
function GetTestsDir: string;
function GetRepoRelativePath(const aPath: string): string;

implementation

uses
  echo_recorder_core_paths;

function GetExecutableDir: string;
begin
  Result := echo_recorder_core_paths.getExecutableDir;
end;

function GetRepoRootDir: string;
begin
  Result := echo_recorder_core_paths.getRepoRootDir;
end;

function GetTestsDir: string;
begin
  Result := echo_recorder_core_paths.getTestsDir;
end;

function GetRepoRelativePath(const aPath: string): string;
begin
  Result := echo_recorder_core_paths.getRepoRelativePath(aPath);
end;

end.
