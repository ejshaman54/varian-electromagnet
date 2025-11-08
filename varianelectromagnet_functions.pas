unit varianelectromagnet_functions;

{$mode objfpc}{$H+}

{------------------------------------------------------------------------------
  Electromagnet serial functions for Lazarus UI

  - Uses Synaser (TBlockSerial) for cross‑platform serial I/O
  - Supports two simple command profiles:
      * cpSCPI   : SCPI‑like supplies (e.g., "SOUR:CURR 2.500" + CR, queries "MEAS:CURR?\n")
      * cpSimple : Minimal MCU protocol (e.g., "SETI 2.500;", "I?;")
  - Provides helpers to open/close the port, set current, toggle output, and
    read back current/field with an optional linear calibration.

  Integration (example):
    uses Functions;

    if InitializeEMSerial then begin
      OutputEnable(True);
      SetCurrent(1.250);
      // ... in a timer:
      var i: Double;
      if QueryCurrent(i) then LabelI.Caption := Format('I = %.3f A',[i]);
    end;

  NOTE: Adjust defaults (DeviceName, Baud, terminators, limits, calibration)
        to match hardware.
------------------------------------------------------------------------------}

interface

uses
  Classes, SysUtils, Synaser;

type
  TCmdProfile = (cpSCPI, cpSimple);

var
  { Public configuration knobs (change at runtime if desired) }
  CmdProfile          : TCmdProfile = cpSCPI;
  DeviceName          : string      = '/dev/ttyUSB0';   { e.g., 'COM3' on Windows }
  Baud                : LongInt     = 9600;             { 9600/19200/38400/... }
  WriteTerm           : string      = #13;              { default TX terminator: CR }
  ReadTermChar        : AnsiChar    = #10;              { expect LF in replies }
  QueryDeadlineMs     : Integer     = 800;              { total wait for a reply }
  ReadChunkTimeoutMs  : Integer     = 60;               { per‑chunk wait }

  { Safety limits and calibration }
  MinCurrentA         : Double      = -5.000;           { edit to your supply limits }
  MaxCurrentA         : Double      =  5.000;
  FieldSlope_T_per_A  : Double      =  0.100;           { B = slope*A + offset (Tesla) }
  FieldOffset_T       : Double      =  0.000;

  { Exposed serial object (read‑only in user code) }
  EMSerial            : TBlockSerial = nil;

function InitializeEMSerial: Boolean;
procedure FreeEMSerial;
function IsEMReady: Boolean;

function OutputEnable(const OnOff: Boolean): Boolean;
function SetCurrent(const Amp: Double): Boolean;
function QueryCurrent(out Amp: Double): Boolean;
function QueryVoltage(out Volts: Double): Boolean;           { optional, SCPI }
function QueryFieldT(out Tesla: Double): Boolean;            { via linear calib }

implementation

{============================== Internals =====================================}

function Clamp(const x, lo, hi: Double): Double; inline;
begin
  if x < lo then Exit(lo) else if x > hi then Exit(hi) else Exit(x);
end;

function NowMs: QWord; inline;
begin
  Result := GetTickCount64;
end;

function BuildSetCurrentCmd(const Amp: Double): string;
begin
  case CmdProfile of
    cpSCPI  : Result := Format('SOUR:CURR %.6f', [Amp]) + WriteTerm;
    cpSimple: Result := Format('SETI %.6f', [Amp]) + ';';
  end;
end;

function BuildOutputOnCmd(const OnOff: Boolean): string;
begin
  case CmdProfile of
    cpSCPI  : Result := 'OUTP ' + IfThen(OnOff, 'ON', 'OFF') + WriteTerm;
    cpSimple: Result := 'OUT '  + IfThen(OnOff, '1',  '0')   + ';';
  end;
end;

function BuildMeasureCurrentQry: string;
begin
  case CmdProfile of
    cpSCPI  : Result := 'MEAS:CURR?' + WriteTerm;   { some supplies use READ? }
    cpSimple: Result := 'I?;';
  end;
end;

function BuildMeasureVoltageQry: string;
begin
  case CmdProfile of
    cpSCPI  : Result := 'MEAS:VOLT?' + WriteTerm;
    cpSimple: Result := 'V?;';
  end;
end;

function ReadUntilTerminated(Ser: TBlockSerial; DeadlineMs, ChunkTimeoutMs: Integer;
  TermCh: AnsiChar): string;
var
  start: QWord;
  ch: AnsiChar;
  s: RawByteString;
begin
  Result := '';
  if Ser = nil then Exit;
  start := NowMs;
  repeat
    if Ser.CanRead(ChunkTimeoutMs) then begin
      s := Ser.RecvString(1);  { read whatever is there }
      Result := Result + string(s);
      if (Result <> '') and (Result[Length(Result)] = TermCh) then Exit;
    end;
  until (NowMs - start >= QWord(DeadlineMs));
end;

function ParseLooseFloat(const S: string; out V: Double): Boolean;
var
  i: Integer; buf: string; c: Char; dotSeen, signSeen: Boolean;
begin
  buf := ''; dotSeen := False; signSeen := False;
  for i := 1 to Length(S) do begin
    c := S[i];
    if (c in ['0'..'9']) then buf += c
    else if (c = '.') and (not dotSeen) then begin buf += c; dotSeen := True; end
    else if (c = '-') and (not signSeen) then begin buf += c; signSeen := True; end
    else if (c = '+') and (not signSeen) then begin buf += c; signSeen := True; end;
  end;
  Result := TryStrToFloat(buf, V);
end;

{============================== API impl ======================================}

function InitializeEMSerial: Boolean;
begin
  Result := False;
  try
    if EMSerial <> nil then FreeEMSerial;
    EMSerial := TBlockSerial.Create;
    EMSerial.RaiseExcept := False;
    {$IFDEF UNIX} EMSerial.LinuxLock := False; {$ENDIF}
    EMSerial.Connect(DeviceName);
    EMSerial.Config(Baud, 8, 'N', SB1, False, False);
    Result := (EMSerial.LastError = 0);
  except
    on E: Exception do begin
      FreeEMSerial;
      Result := False;
    end;
  end;
end;

procedure FreeEMSerial;
begin
  if EMSerial <> nil then begin
    try EMSerial.Purge; except end;
    FreeAndNil(EMSerial);
  end;
end;

function IsEMReady: Boolean;
begin
  Result := (EMSerial <> nil) and (EMSerial.LastError = 0);
end;

function OutputEnable(const OnOff: Boolean): Boolean;
var
  cmd: string;
begin
  Result := False;
  if not IsEMReady then Exit;
  cmd := BuildOutputOnCmd(OnOff);
  EMSerial.SendString(cmd);
  Result := (EMSerial.LastError = 0);
end;

function SetCurrent(const Amp: Double): Boolean;
var
  a: Double;
  cmd: string;
begin
  Result := False;
  if not IsEMReady then Exit;
  a := Clamp(Amp, MinCurrentA, MaxCurrentA);
  cmd := BuildSetCurrentCmd(a);
  EMSerial.SendString(cmd);
  Result := (EMSerial.LastError = 0);
end;

function QueryCurrent(out Amp: Double): Boolean;
var
  q, rep: string;
  val: Double;
begin
  Amp := NaN;
  Result := False;
  if not IsEMReady then Exit;
  q := BuildMeasureCurrentQry;
  EMSerial.SendString(q);
  rep := ReadUntilTerminated(EMSerial, QueryDeadlineMs, ReadChunkTimeoutMs, ReadTermChar);
  if rep = '' then Exit(False);
  if ParseLooseFloat(rep, val) then begin Amp := val; Result := True; end;
end;

function QueryVoltage(out Volts: Double): Boolean;
var
  q, rep: string;
  val: Double;
begin
  Volts := NaN;
  Result := False;
  if not IsEMReady then Exit;
  q := BuildMeasureVoltageQry;
  EMSerial.SendString(q);
  rep := ReadUntilTerminated(EMSerial, QueryDeadlineMs, ReadChunkTimeoutMs, ReadTermChar);
  if rep = '' then Exit(False);
  if ParseLooseFloat(rep, val) then begin Volts := val; Result := True; end;
end;

function QueryFieldT(out Tesla: Double): Boolean;
var I: Double;
begin
  Tesla := NaN;
  if not QueryCurrent(I) then Exit(False);
  Tesla := FieldSlope_T_per_A * I + FieldOffset_T;
  Result := True;
end;

end.

