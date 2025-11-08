unit varianelectromagnet_ui;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  ComCtrls, DateUtils;

type
  { TForm1 }
  TForm1 = class(TForm)
    btnConnect: TButton;
    btnDisconnect: TButton;
    btnEStop: TButton;
    btnPoll: TButton;
    btnRefreshPorts: TButton;
    btnSetImmediate: TButton;
    btnStartRamp: TButton;
    btnStopRamp: TButton;
    btnZero: TButton;
    cbPort: TComboBox;
    chkReverse: TCheckBox;
    edHoldTime: TEdit;
    edRampRate: TEdit;
    edTargetA: TEdit;
    gbConn: TGroupBox;
    gbReadback: TGroupBox;
    gbRamp: TGroupBox;
    gbSetpoint: TGroupBox;
    lblField: TLabel;
    lblIRead: TLabel;
    lblStatus: TLabel;
    lblVRead: TLabel;
    tmrPoll: TTimer;
    tmrRamp: TTimer;
    tbSetA: TTrackBar;
    procedure btnConnectClick(Sender: TObject);
    procedure btnDisconnectClick(Sender: TObject);
    procedure btnEStopClick(Sender: TObject);
    procedure btnPollClick(Sender: TObject);
    procedure btnRefreshPortsClick(Sender: TObject);
    procedure btnSetImmediateClick(Sender: TObject);
    procedure btnStartRampClick(Sender: TObject);
    procedure btnStopRampClick(Sender: TObject);
    procedure btnZeroClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure tmrPollTimer(Sender: TObject);
    procedure tmrRampTimer(Sender: TObject);
    procedure tbSetAChange(Sender: TObject);
  private
    // --- abstract hardware state ---
    FConnected: Boolean;
    FUseSerial: Boolean;   // set TRUE for serial, FALSE for DAQ (Comedi)
    FCurrentSet: Double;   // last commanded setpoint (A)
    FCurrentRead: Double;  // last measured current (A)

    // --- ramp state ---
    FRampActive: Boolean;
    FRampRateAps: Double;  // A/s
    FTargetA: Double;
    FRampStartA: Double;
    FRampStartTime: TDateTime;
    FHoldSeconds: Double;

    // --- serial placeholders ---
    procedure SerialRefreshPorts;
    function  SerialConnect(const APort: string): Boolean;
    procedure SerialDisconnect;
    function  SerialSend(const S: string): Boolean;
    function  SerialQuery(const S: string; out Reply: string): Boolean;

    // --- DAQ placeholders (replace with Comedi/NI calls) ---
    function  WriteDacVoltage(Volts: Double): Boolean;
    function  ReadbackCurrent(out A: Double): Boolean;

    procedure ApplySetpoint(Ampere: Double);
    procedure UpdateUiState;
  public
  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

{ ====== UI helpers ====== }

procedure TForm1.FormCreate(Sender: TObject);
begin
  Caption := 'Varian Electromagnet Controller';
  FConnected := False;
  FUseSerial := True;  // toggle here: TRUE for serial, FALSE for DAQ
  FRampActive := False;
  FRampRateAps := 0.1;
  FTargetA := 0.0;
  FRampStartA := 0.0;
  FHoldSeconds := 0.0;

  edTargetA.Text := '0.00';
  edRampRate.Text := '0.10';
  edHoldTime.Text := '0.0';

  SerialRefreshPorts;
  UpdateUiState;
end;

procedure TForm1.UpdateUiState;
begin
  lblStatus.Caption := IfThen(FConnected, 'Status: Connected', 'Status: Disconnected');
  btnConnect.Enabled := (not FConnected);
  btnDisconnect.Enabled := FConnected;
  btnSetImmediate.Enabled := FConnected;
  btnZero.Enabled := FConnected;
  btnStartRamp.Enabled := FConnected and (not FRampActive);
  btnStopRamp.Enabled := FRampActive;
  btnEStop.Enabled := FConnected;
end;

procedure TForm1.tbSetAChange(Sender: TObject);
var a: Double;
begin
  a := tbSetA.Position / 1000.0; // mA -> A
  edTargetA.Text := Format('%.3f', [a]);
end;

{ ====== Connection ====== }

procedure TForm1.SerialRefreshPorts;
begin
  // Minimal: let the user type the port; optionally enumerate.
  cbPort.Items.Clear;
  {$IFDEF Windows}
  cbPort.Items.Add('COM3');
  cbPort.Items.Add('COM4');
  {$ELSE}
  cbPort.Items.Add('/dev/ttyUSB0');
  cbPort.Items.Add('/dev/ttyACM0');
  {$ENDIF}
  if cbPort.Items.Count>0 then cbPort.ItemIndex := 0;
end;

procedure TForm1.btnRefreshPortsClick(Sender: TObject);
begin
  SerialRefreshPorts;
end;

procedure TForm1.btnConnectClick(Sender: TObject);
begin
  if FUseSerial then
  begin
    if SerialConnect(cbPort.Text) then
      FConnected := True
    else
      ShowMessage('Failed to open serial port.');
  end
  else
  begin
    // DAQ initialization here (open device, config subdevice/channel)
    FConnected := True;
  end;
  UpdateUiState;
end;

procedure TForm1.btnDisconnectClick(Sender: TObject);
begin
  if FUseSerial then
    SerialDisconnect
  else
    ; // close DAQ

  FConnected := False;
  UpdateUiState;
end;

{ ====== Setpoint actions ====== }

procedure TForm1.ApplySetpoint(Ampere: Double);
var cmd: string;
    volts: Double;
begin
  // Apply polarity if needed
  if chkReverse.Checked then
    Ampere := -Ampere;

  FCurrentSet := Ampere;

  if FUseSerial then
  begin
    // ***** EDIT THESE COMMANDS TO MATCH SUPPLY/MICROCONTROLLER *****
    // Common patterns: 'SETI 2.500', 'ISET 2.500', 'CURR 2.500', or SCPI: 'SOUR:CURR 2.5'
    cmd := Format('SETI %.3f'#13, [Ampere]);
    if not SerialSend(cmd) then
      ShowMessage('Serial write failed.');
  end
  else
  begin
    // Map current to DAC volts (edit to your calibration!)
    // Example: 1.000 A => 1.000 V  (placeholder)
    volts := Ampere;
    if not WriteDacVoltage(volts) then
      ShowMessage('DAQ write failed.');
  end;
end;

procedure TForm1.btnSetImmediateClick(Sender: TObject);
var a: Double;
begin
  if not FConnected then Exit;
  if TryStrToFloat(edTargetA.Text, a) then
    ApplySetpoint(a)
  else
    ShowMessage('Invalid target current.');
end;

procedure TForm1.btnZeroClick(Sender: TObject);
begin
  if not FConnected then Exit;
  ApplySetpoint(0.0);
end;

{ ====== Ramp control ====== }

procedure TForm1.btnStartRampClick(Sender: TObject);
begin
  if not FConnected then Exit;
  if not TryStrToFloat(edTargetA.Text, FTargetA) then
  begin
    ShowMessage('Invalid target current.');
    Exit;
  end;
  if not TryStrToFloat(edRampRate.Text, FRampRateAps) then
  begin
    ShowMessage('Invalid ramp rate (A/s).');
    Exit;
  end;
  if not TryStrToFloat(edHoldTime.Text, FHoldSeconds) then
    FHoldSeconds := 0.0;

  FRampStartA := FCurrentSet;
  FRampStartTime := Now;
  FRampActive := True;
  tmrRamp.Enabled := True;
  UpdateUiState;
end;

procedure TForm1.btnStopRampClick(Sender: TObject);
begin
  FRampActive := False;
  tmrRamp.Enabled := False;
  UpdateUiState;
end;

procedure TForm1.tmrRampTimer(Sender: TObject);
var tsec, dir, delta, nextA: Double;
begin
  if not FRampActive then Exit;

  tsec := (Now - FRampStartTime) * 24 * 3600.0;
  dir := Sign(FTargetA - FRampStartA);
  delta := dir * FRampRateAps * tsec;
  nextA := FRampStartA + delta;

  // Clamp to target
  if ((dir>0) and (nextA >= FTargetA)) or ((dir<0) and (nextA <= FTargetA)) then
  begin
    nextA := FTargetA;
    ApplySetpoint(nextA);
    // optionally hold
    if FHoldSeconds > 0 then
    begin
      // crude hold: wait via timer—keep tmrRamp running until hold done
      if tsec >= Abs(FTargetA - FRampStartA)/FRampRateAps + FHoldSeconds then
      begin
        FRampActive := False;
        tmrRamp.Enabled := False;
        UpdateUiState;
      end;
    end
    else
    begin
      FRampActive := False;
      tmrRamp.Enabled := False;
      UpdateUiState;
    end;
    Exit;
  end;

  ApplySetpoint(nextA);
end;

{ ====== Polling / Readback ====== }

procedure TForm1.btnPollClick(Sender: TObject);
begin
  tmrPollTimer(nil);
end;

procedure TForm1.tmrPollTimer(Sender: TObject);
var rep: string;
    a: Double;
begin
  if not FConnected then Exit;

  if FUseSerial then
  begin
    // ***** EDIT THESE TO MATCH DEVICE *****
    // Common patterns: query 'MEASI?', 'READ?', 'CURR?', 'MEAS:CURR?'
    if SerialQuery('MEASI?'#13, rep) then
    begin
      // Parse reply like "I=2.500"
      if TryStrToFloat(StringReplace(rep, 'I=', '', []), a) then
        FCurrentRead := a;
    end;
  end
  else
  begin
    if not ReadbackCurrent(a) then
      Exit;
    FCurrentRead := a;
  end;

  lblIRead.Caption := Format('I = %.3f A', [FCurrentRead]);
  // Optional conversions:
  lblField.Caption := Format('B = %.1f mT', [FCurrentRead * 100.0]); // placeholder
  lblVRead.Caption := 'V = (n/a)';
end;

{ ====== Emergency stop ====== }

procedure TForm1.btnEStopClick(Sender: TObject);
begin
  FRampActive := False;
  tmrRamp.Enabled := False;
  ApplySetpoint(0.0);  // drop to zero immediately
end;

{ ====== Serial stubs (replace with LazSerial or Synaser) ====== }

function TForm1.SerialConnect(const APort: string): Boolean;
begin
  // Replace with LazSerial or Synaser implementation.
  // Return True if successfully opened.
  Result := True;  // placeholder
end;

procedure TForm1.SerialDisconnect;
begin
  // Close port
end;

function TForm1.SerialSend(const S: string): Boolean;
begin
  // Write S to serial
  Result := True; // placeholder
end;

function TForm1.SerialQuery(const S: string; out Reply: string): Boolean;
begin
  // Send S, read reply into Reply
  Reply := 'I=0.000'; // placeholder
  Result := True;
end;

{ ====== DAQ stubs (replace with Comedi/NI calls) ====== }

function TForm1.WriteDacVoltage(Volts: Double): Boolean;
begin
  // Map Volts to AO channel
  Result := True; // placeholder
end;

function TForm1.ReadbackCurrent(out A: Double): Boolean;
begin
  // Read from shunt via AI (convert V->A)
  A := FCurrentSet; // placeholder (assume perfect tracking)
  Result := True;
end;

end.

