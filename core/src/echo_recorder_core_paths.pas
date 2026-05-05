unit echo_recorder_core_paths;

{$mode objfpc}{$H+}

interface

function    getExecutableDir: string;
function    getRepoRootDir: string;
function    getWorkspaceRootDir: string;
function    getTestsDir: string;
function    getRepoRelativePath(const aPath: string): string;

implementation

uses
  SysUtils;

function getExecutableDir: string;
begin
  Result := ExcludeTrailingPathDelimiter(ExtractFileDir(ParamStr(0)));
end;

function getRepoRootDir: string;
begin
  Result := ExcludeTrailingPathDelimiter(
    ExpandFileName(getExecutableDir + PathDelim + '..' + PathDelim + '..' + PathDelim + '..')
  );
end;

function getWorkspaceRootDir: string;
begin
  Result := ExcludeTrailingPathDelimiter(
    ExpandFileName(getRepoRootDir + PathDelim + '..')
  );
end;

function getTestsDir: string;
begin
  Result := IncludeTrailingPathDelimiter(getRepoRootDir) + 'tests';
end;

function getRepoRelativePath(const aPath: string): string;
var
  root: string;
begin
  root := IncludeTrailingPathDelimiter(getRepoRootDir);
  Result := ExtractRelativePath(root, ExpandFileName(aPath));
end;

end.