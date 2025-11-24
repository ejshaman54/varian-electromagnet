unit daq_comedi;

{$mode objfpc}{$H+}

interface

type
  PComedi_t = Pointer;
  lsampl_t  = Cardinal;

  TComediDAQ = record
    Dev          : PComedi_t;
    DevName      : AnsiString;  // e.g. '/dev/comedi0'
    SubdevAO     : Integer;      // analog output subdevice index
    SubdevAI     : Integer;      // analog input subdevice index
    SubdevDO     : Integer;      // digital output subdevice index (optional)
    SubdevDI     : Integer;      // digital input subdevice index (optional)
    AOChan       : Integer;      // which AO channel drives the magnet PSU
    AIChan       : Integer;      // which AI channel reads back a monitor (shunt/Hall)
    AORange      : Integer;      // range index for AO
    AIRange      : Integer;      // range index for AI
    AORef        : Integer;      // aref (0=ground, 1=common, 2=diff). Usually 0
    AIRef        : Integer;      // same for AI
    MaxAOSample  : lsampl_t;
    MaxAISample  : lsampl_t;
  end;

function Comedi_Init(var D: TComediDAQ; const Device: AnsiString = '/dev/comedi0';
                     AO_Subdev: Integer = -1; AI_Subdev: Integer = -1): Boolean;
procedure Comedi_Close(var D: TComediDAQ);

function Comedi_WriteAO_Volts(var D: TComediDAQ; volts: Double): Boolean;
function Comedi_ReadAI_Volts(var D: TComediDAQ; out volts: Double): Boolean;

function Comedi_SetDO(var D: TComediDAQ; chan: Integer; value: Boolean): Boolean;
function Comedi_GetDI(var D: TComediDAQ; chan: Integer; out value: Boolean): Boolean;

implementation

// --- Comedi C API bindings (dynamic link to libcomedi) ---
function comedi_open(const fname: PChar): PComedi_t; cdecl; external 'comedi';
function comedi_close(dev: PComedi_t): Longint; cdecl; external 'comedi';

function comedi_find_subdevice_by_type(dev: PComedi_t; sdt: Longint; start: Longint): Longint; cdecl; external 'comedi';
function comedi_get_maxdata(dev: PComedi_t; subdev, chan: Longint): lsampl_t; cdecl; external 'comedi';
function comedi_get_n_ranges(dev: PComedi_t; subdev, chan: Longint): Longint; cdecl; external 'comedi';
function comedi_get_range(dev: PComedi_t; subdev, chan, range: Longint): Pointer; cdecl; external 'comedi';

function comedi_data_write(dev: PComedi_t; subdev, chan, range, aref: Longint; data: lsampl_t): Longint; cdecl; external 'comedi';
function comedi_data_read(dev: PComedi_t; subdev, chan, range, aref: Longint; var data: lsampl_t): Longint; cdecl; external 'comedi';

function comedi_to_phys(data: lsampl_t; rng: Pointer; maxdata: lsampl_t): Double; cdecl; external 'comedi';
function comedi_from_phys(phys: Double; rng: Pointer; maxdata: lsampl_t): lsampl_t; cdecl; external 'comedi';

// Subdevice type constants (from comedi.h)
const
  COMEDI_SUBD_AI = 0;
  COMEDI_SUBD_AO = 1;
  COMEDI_SUBD_DI = 2;
  COMEDI_SUBD_DO = 3;

// ARef constants (from comedi.h). 0=GND, 1=COMMON, 2=DIFF
  AREF_GROUND = 0;

function Comedi_Init(var D: TComediDAQ; const Device: AnsiString; AO_Subdev: Integer; AI_Subdev: Integer): Boolean;
begin
  FillChar(D, SizeOf(D), 0);
  D.DevName := Device;
  D.AORef := AREF_GROUND;
  D.AIRef := AREF_GROUND;

  D.Dev := comedi_open(PChar(D.DevName));
  if D.Dev = nil then
    exit(False);

  // Find subdevices if caller didn't specify them
  if AO_Subdev >= 0 then D.SubdevAO := AO_Subdev
  else D.SubdevAO := comedi_find_subdevice_by_type(D.Dev, COMEDI_SUBD_AO, 0);

  if AI_Subdev >= 0 then D.SubdevAI := AI_Subdev
  else D.SubdevAI := comedi_find_subdevice_by_type(D.Dev, COMEDI_SUBD_AI, 0);

  // Optional DO/DI
  D.SubdevDO := comedi_find_subdevice_by_type(D.Dev, COMEDI_SUBD_DO, 0);
  D.SubdevDI := comedi_find_subdevice_by_type(D.Dev, COMEDI_SUBD_DI, 0);

  // Default channel/range selection (caller can override these fields later)
  D.AOChan := 0;
  D.AIChan := 0;
  D.AORange := 0;
  D.AIRange := 0;

  // Cache maxdata
  if D.SubdevAO >= 0 then
    D.MaxAOSample := comedi_get_maxdata(D.Dev, D.SubdevAO, D.AOChan);
  if D.SubdevAI >= 0 then
    D.MaxAISample := comedi_get_maxdata(D.Dev, D.SubdevAI, D.AIChan);

  Result := (D.SubdevAO >= 0) or (D.SubdevAI >= 0);
end;

procedure Comedi_Close(var D: TComediDAQ);
begin
  if D.Dev <> nil then
    comedi_close(D.Dev);
  D.Dev := nil;
end;

function Comedi_WriteAO_Volts(var D: TComediDAQ; volts: Double): Boolean;
var
  rng: Pointer;
  code: lsampl_t;
begin
  if (D.Dev = nil) or (D.SubdevAO < 0) then exit(False);
  rng := comedi_get_range(D.Dev, D.SubdevAO, D.AOChan, D.AORange);
  code := comedi_from_phys(volts, rng, D.MaxAOSample);
  Result := comedi_data_write(D.Dev, D.SubdevAO, D.AOChan, D.AORange, D.AORef, code) >= 0;
end;

function Comedi_ReadAI_Volts(var D: TComediDAQ; out volts: Double): Boolean;
var
  rng: Pointer;
  code: lsampl_t;
begin
  volts := 0.0;
  if (D.Dev = nil) or (D.SubdevAI < 0) then exit(False);
  if comedi_data_read(D.Dev, D.SubdevAI, D.AIChan, D.AIRange, D.AIRef, code) < 0 then
    exit(False);
  rng := comedi_get_range(D.Dev, D.SubdevAI, D.AIChan, D.AIRange);
  volts := comedi_to_phys(code, rng, D.MaxAISample);
  Result := True;
end;

function Comedi_SetDO(var D: TComediDAQ; chan: Integer; value: Boolean): Boolean;
var
  code: lsampl_t;
begin
  if (D.Dev = nil) or (D.SubdevDO < 0) then exit(False);
  code := Ord(value);
  Result := comedi_data_write(D.Dev, D.SubdevDO, chan, 0, 0, code) >= 0;
end;

function Comedi_GetDI(var D: TComediDAQ; chan: Integer; out value: Boolean): Boolean;
var
  code: lsampl_t;
begin
  value := False;
  if (D.Dev = nil) or (D.SubdevDI < 0) then exit(False);
  if comedi_data_read(D.Dev, D.SubdevDI, chan, 0, 0, code) < 0 then exit(False);
  value := (code <> 0);
  Result := True;
end;

end.
