unit electromagnet_daq;

{$mode objfpc}{$H+}

interface

uses
  daq_comedi;

type
  TElectroMagnet = record
    DAQ       : TComediDAQ;
    // Calibration parameters (tune these to your hardware):
    // Supply is programmed by 1.000 V/A (example), clamp at +/-10 V
    Prog_V_per_A : Double;
    AO_V_Max     : Double;
    AO_V_Min     : Double;
    // Readback monitor: e.g. 0.100 V/A across a shunt
    Mon_V_per_A  : Double;
  end;

function EM_Init(var EM: TElectroMagnet; const Dev: AnsiString = '/dev/comedi0'): Boolean;
procedure EM_Close(var EM: TElectroMagnet);

function EM_SetCurrentA(var EM: TElectroMagnet; amps: Double): Boolean;
function EM_ReadCurrentA(var EM: TElectroMagnet; out amps: Double): Boolean;

implementation

uses Math;

function EM_Init(var EM: TElectroMagnet; const Dev: AnsiString): Boolean;
begin
  // Defaults (override in your GUI if needed)
  EM.Prog_V_per_A := 1.0;   // 1 V per 1 A programming input
  EM.Mon_V_per_A  := 0.1;   // 100 mV per 1 A monitor
  EM.AO_V_Max     := 10.0;
  EM.AO_V_Min     := -10.0;

  Result := Comedi_Init(EM.DAQ, Dev, -1, -1);
  if not Result then Exit;

  // Choose channels/ranges (adjust to your board):
  EM.DAQ.AOChan  := 0;  // AO0 → magnet PSU program in
  EM.DAQ.AIChan  := 0;  // AI0 ← monitor/shunt
  EM.DAQ.AORange := 0;  // usually 0 corresponds to ±10 V (verify)
  EM.DAQ.AIRange := 0;  // e.g. ±10 V
end;

procedure EM_Close(var EM: TElectroMagnet);
begin
  Comedi_Close(EM.DAQ);
end;

function EM_SetCurrentA(var EM: TElectroMagnet; amps: Double): Boolean;
var
  vprog: Double;
begin
  vprog := amps * EM.Prog_V_per_A;
  vprog := EnsureRange(vprog, EM.AO_V_Min, EM.AO_V_Max);
  Result := Comedi_WriteAO_Volts(EM.DAQ, vprog);
end;

function EM_ReadCurrentA(var EM: TElectroMagnet; out amps: Double): Boolean;
var
  vmon: Double;
begin
  amps := 0.0;
  if not Comedi_ReadAI_Volts(EM.DAQ, vmon) then exit(False);
  // simple linear monitor conversion
  amps := vmon / EM.Mon_V_per_A;
  Result := True;
end;

end.
